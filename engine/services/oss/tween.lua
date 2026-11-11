---@alias EasingFunction fun(t:number, b:number, c:number, d:number, ...): number
---@alias EasingName
---| 'linear'
---| 'stepped'
---| 'steppedN'
---| 'bounceStep'
---| 'inQuad' | 'outQuad' | 'inOutQuad' | 'outInQuad'
---| 'inCubic' | 'outCubic' | 'inOutCubic' | 'outInCubic'
---| 'inQuart' | 'outQuart' | 'inOutQuart' | 'outInQuart'
---| 'inQuint' | 'outQuint' | 'inOutQuint' | 'outInQuint'
---| 'inSine' | 'outSine' | 'inOutSine' | 'outInSine'
---| 'inExpo' | 'outExpo' | 'inOutExpo' | 'outInExpo'
---| 'inCirc' | 'outCirc' | 'inOutCirc' | 'outInCirc'
---| 'inElastic' | 'outElastic' | 'inOutElastic' | 'outInElastic'
---| 'inBack' | 'outBack' | 'inOutBack' | 'outInBack'
---| 'inBounce' | 'outBounce' | 'inOutBounce' | 'outInBounce'
---| 'squashAndStretch'

---@class TweenArgs
---@field pausable boolean?            -- if true, goes into pausable group
---@field completeFunc fun()?          -- called once when tween completes and is removed
---@field constFunc fun()?             -- called every update before interpolation
---@field drawFunc fun()?              -- called in tween.draw
---@field reverses boolean?            -- if true, auto-reverses each cycle
---@field loop (boolean|number)?       -- true=infinite, number=times, false/0=none
---@field interface boolean?           -- marks an interface transition: completes instantly when the reduced_motion setting is on

---@class Tween
---@field duration number
---@field subject table|Element|userdata
---@field target table
---@field easing EasingFunction
---@field clock number
---@field pausable boolean?
---@field completeFunc fun()
---@field constFunc fun()
---@field drawFunc fun()
---@field reverses boolean?
---@field loop (boolean|number)?
---@field _loopsLeft number
---@field _reversed boolean
---@field _initial0 table
---@field _target0 table
---@field set fun(self:Tween, clock:number): boolean
---@field reset fun(self:Tween): boolean
---@field update fun(self:Tween, dt:number): boolean
---@field destroy fun(self:Tween)

tween = {
  _VERSION = 'tween 2.1.1',
  _DESCRIPTION = 'tweening for lua',
  _URL = 'https://github.com/kikito/tween.lua',
  _LICENSE = [[
    MIT LICENSE

    Copyright (c) 2014 Enrique García Cota, Yuichi Tateno, Emmanuel Oga

    Permission is hereby granted, free of charge, to any person obtaining a
    copy of this software and associated documentation files (the
    "Software"), to deal in the Software without restriction, including
    without limitation the rights to use, copy, modify, merge, publish,
    distribute, sublicense, and/or sell copies of the Software, and to
    permit persons to whom the Software is furnished to do so, subject to
    the following conditions:

    The above copyright notice and this permission notice shall be included
    in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
    OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
    MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
    IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
    CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
    TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
    SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
  ]],
  alltweens = { ['pausable'] = {}, ['unpausable'] = {}, }
}

-- easing

-- Adapted from https://github.com/EmmanuelOga/easing. See LICENSE.txt for credits.
-- For all easing functions:
-- t = time (how much time has passed so far)
-- b = begin (starting property value)
-- c = change (ending value minus beginning)
-- d = duration (total duration of the tween)

local pow, sin, cos, pi, sqrt, abs, asin = math.pow, math.sin, math.cos, math.pi, math.sqrt, math.abs, math.asin

-- linear
local function linear(t, b, c, d)
  return c * t / d + b
end

-- quad
local function inQuad(t, b, c, d)
  return c * pow(t / d, 2) + b
end
local function outQuad(t, b, c, d)
  t = t / d
  return -c * t * (t - 2) + b
end
local function inOutQuad(t, b, c, d)
  t = t / d * 2
  if t < 1 then
    return c / 2 * pow(t, 2) + b
  end
  return -c / 2 * ((t - 1) * (t - 3) - 1) + b
end
local function outInQuad(t, b, c, d)
  if t < d / 2 then
    return outQuad(t * 2, b, c / 2, d)
  end
  return inQuad((t * 2) - d, b + c / 2, c / 2, d)
end

-- cubic
local function inCubic(t, b, c, d)
  return c * pow(t / d, 3) + b
end
local function outCubic(t, b, c, d)
  return c * (pow(t / d - 1, 3) + 1) + b
end
local function inOutCubic(t, b, c, d)
  t = t / d * 2
  if t < 1 then
    return c / 2 * t * t * t + b
  end
  t = t - 2
  return c / 2 * (t * t * t + 2) + b
end
local function outInCubic(t, b, c, d)
  if t < d / 2 then
    return outCubic(t * 2, b, c / 2, d)
  end
  return inCubic((t * 2) - d, b + c / 2, c / 2, d)
end

-- quart
local function inQuart(t, b, c, d)
  return c * pow(t / d, 4) + b
end
local function outQuart(t, b, c, d)
  return -c * (pow(t / d - 1, 4) - 1) + b
end
local function inOutQuart(t, b, c, d)
  t = t / d * 2
  if t < 1 then
    return c / 2 * pow(t, 4) + b
  end
  return -c / 2 * (pow(t - 2, 4) - 2) + b
end
local function outInQuart(t, b, c, d)
  if t < d / 2 then
    return outQuart(t * 2, b, c / 2, d)
  end
  return inQuart((t * 2) - d, b + c / 2, c / 2, d)
end

-- quint
local function inQuint(t, b, c, d)
  return c * pow(t / d, 5) + b
end
local function outQuint(t, b, c, d)
  return c * (pow(t / d - 1, 5) + 1) + b
end
local function inOutQuint(t, b, c, d)
  t = t / d * 2
  if t < 1 then
    return c / 2 * pow(t, 5) + b
  end
  return c / 2 * (pow(t - 2, 5) + 2) + b
end
local function outInQuint(t, b, c, d)
  if t < d / 2 then
    return outQuint(t * 2, b, c / 2, d)
  end
  return inQuint((t * 2) - d, b + c / 2, c / 2, d)
end

-- sine
local function inSine(t, b, c, d)
  return -c * cos(t / d * (pi / 2)) + c + b
end
local function outSine(t, b, c, d)
  return c * sin(t / d * (pi / 2)) + b
end
local function inOutSine(t, b, c, d)
  return -c / 2 * (cos(pi * t / d) - 1) + b
end
local function outInSine(t, b, c, d)
  if t < d / 2 then
    return outSine(t * 2, b, c / 2, d)
  end
  return inSine((t * 2) - d, b + c / 2, c / 2, d)
end

-- expo
local function inExpo(t, b, c, d)
  if t == 0 then
    return b
  end
  return c * pow(2, 10 * (t / d - 1)) + b - c * 0.001
end
local function outExpo(t, b, c, d)
  if t == d then
    return b + c
  end
  return c * 1.001 * (-pow(2, -10 * t / d) + 1) + b
end
local function inOutExpo(t, b, c, d)
  if t == 0 then
    return b
  end
  if t == d then
    return b + c
  end
  t = t / d * 2
  if t < 1 then
    return c / 2 * pow(2, 10 * (t - 1)) + b - c * 0.0005
  end
  return c / 2 * 1.0005 * (-pow(2, -10 * (t - 1)) + 2) + b
end
local function outInExpo(t, b, c, d)
  if t < d / 2 then
    return outExpo(t * 2, b, c / 2, d)
  end
  return inExpo((t * 2) - d, b + c / 2, c / 2, d)
end

-- circ
local function inCirc(t, b, c, d)
  return (-c * (sqrt(1 - pow(t / d, 2)) - 1) + b)
end
local function outCirc(t, b, c, d)
  return (c * sqrt(1 - pow(t / d - 1, 2)) + b)
end
local function inOutCirc(t, b, c, d)
  t = t / d * 2
  if t < 1 then
    return -c / 2 * (sqrt(1 - t * t) - 1) + b
  end
  t = t - 2
  return c / 2 * (sqrt(1 - t * t) + 1) + b
end
local function outInCirc(t, b, c, d)
  if t < d / 2 then
    return outCirc(t * 2, b, c / 2, d)
  end
  return inCirc((t * 2) - d, b + c / 2, c / 2, d)
end

-- elastic
local function calculatePAS(p, a, c, d)
  p, a = p or d * 0.3, a or 0
  if a < abs(c) then
    return p, c, p / 4
  end                                     -- p, a, s
  return p, a, p / (2 * pi) * asin(c / a) -- p, a, s
end
local function inElastic(t, b, c, d, a, p)
  local s
  if t == 0 then
    return b
  end
  t = t / d
  if t == 1 then
    return b + c
  end
  p, a, s = calculatePAS(p, a, c, d)
  t = t - 1
  return -(a * pow(2, 10 * t) * sin((t * d - s) * (2 * pi) / p)) + b
end
local function outElastic(t, b, c, d, a, p)
  local s
  if t == 0 then
    return b
  end
  t = t / d
  if t == 1 then
    return b + c
  end
  p, a, s = calculatePAS(p, a, c, d)
  return a * pow(2, -10 * t) * sin((t * d - s) * (2 * pi) / p) + c + b
end
local function inOutElastic(t, b, c, d, a, p)
  local s
  if t == 0 then
    return b
  end
  t = t / d * 2
  if t == 2 then
    return b + c
  end
  p, a, s = calculatePAS(p, a, c, d)
  t = t - 1
  if t < 0 then
    return -0.5 * (a * pow(2, 10 * t) * sin((t * d - s) * (2 * pi) / p)) + b
  end
  return a * pow(2, -10 * t) * sin((t * d - s) * (2 * pi) / p) * 0.5 + c + b
end
local function outInElastic(t, b, c, d, a, p)
  if t < d / 2 then
    return outElastic(t * 2, b, c / 2, d, a, p)
  end
  return inElastic((t * 2) - d, b + c / 2, c / 2, d, a, p)
end

-- back
local function inBack(t, b, c, d, s)
  s = s or 1.70158
  t = t / d
  return c * t * t * ((s + 1) * t - s) + b
end
local function outBack(t, b, c, d, s)
  s = s or 1.70158
  t = t / d - 1
  return c * (t * t * ((s + 1) * t + s) + 1) + b
end
local function inOutBack(t, b, c, d, s)
  s = (s or 1.70158) * 1.525
  t = t / d * 2
  if t < 1 then
    return c / 2 * (t * t * ((s + 1) * t - s)) + b
  end
  t = t - 2
  return c / 2 * (t * t * ((s + 1) * t + s) + 2) + b
end
local function outInBack(t, b, c, d, s)
  if t < d / 2 then
    return outBack(t * 2, b, c / 2, d, s)
  end
  return inBack((t * 2) - d, b + c / 2, c / 2, d, s)
end

-- bounce
local function outBounce(t, b, c, d)
  t = t / d
  if t < 1 / 2.75 then
    return c * (7.5625 * t * t) + b
  end
  if t < 2 / 2.75 then
    t = t - (1.5 / 2.75)
    return c * (7.5625 * t * t + 0.75) + b
  elseif t < 2.5 / 2.75 then
    t = t - (2.25 / 2.75)
    return c * (7.5625 * t * t + 0.9375) + b
  end
  t = t - (2.625 / 2.75)
  return c * (7.5625 * t * t + 0.984375) + b
end
local function inBounce(t, b, c, d)
  return c - outBounce(d - t, 0, c, d) + b
end
local function inOutBounce(t, b, c, d)
  if t < d / 2 then
    return inBounce(t * 2, 0, c, d) * 0.5 + b
  end
  return outBounce(t * 2 - d, 0, c, d) * 0.5 + c * .5 + b
end
local function outInBounce(t, b, c, d)
  if t < d / 2 then
    return outBounce(t * 2, b, c / 2, d)
  end
  return inBounce((t * 2) - d, b + c / 2, c / 2, d)
end
local function squashAndStretch(t, b, c, d)
  local p = t / d
  local overshootAmplitude = 0.5
  local damping = math.exp(-3 * p)
  return b + c * p + c * overshootAmplitude * damping * sin(6 * pi * p)
end

local function stepped(t, b, c, d, steps)
  steps = steps or 10
  local chunk = math.floor((t / d) * steps)
  if chunk > steps then chunk = steps end
  return b + c * (chunk / steps)
end

local function makeStepped(steps)
  steps = steps or 10
  return function(t, b, c, d)
    local chunk = math.floor((t / d) * steps)
    if chunk > steps then chunk = steps end
    return b + c * (chunk / steps)
  end
end

local function bounceStep(opts)
  opts        = opts or {}
  local steps = math.max(2, opts.steps or 10)                -- >=2 or it "jumps"
  local mode  = opts.mode or "time"                          -- "time" or "value"
  local delay = math.max(0, math.min(0.99, opts.delay or 0)) -- fraction of d to wait
  local amp   = opts.amp or 0.15                             -- squish amplitude (0–0.3 is sane)
  local freq  = opts.freq or 8                               -- oscillations
  local decay = opts.decay or 4                              -- bigger = die out faster

  return function(t, b, c, d)
    if not d or d <= 0 then return b end
    t = math.min(math.max(t, 0), d)

    -- 1) delay block (hold at start)
    local hold = d * delay
    if t < hold then
      return b
    end

    -- work in the remaining segment
    local lt = t - hold
    local ld = d - hold

    -- 2) apply step quantization (time or value)
    local ob_t = lt
    if mode == "time" then
      local r = math.floor((lt / ld) * steps) / steps
      ob_t = r * ld
    end

    -- base bounce value
    local base = outBounce(ob_t, b, c, ld)

    if mode == "value" then
      if c == 0 then return base end
      local prog = (base - b) / c
      prog = math.floor(prog * steps) / steps
      base = b + c * prog
    end

    -- 3) squishy tail: damped sine added to progress
    local p = lt / ld
    local squish = amp * math.exp(-decay * p) * math.sin(freq * math.pi * p)

    return base + c * squish
  end
end

---@type table<string, EasingFunction>
tween.easing = {
  linear = linear,
  stepped = stepped,
  steppedN = makeStepped,
  bounceStep = bounceStep,
  inQuad = inQuad,
  outQuad = outQuad,
  inOutQuad = inOutQuad,
  outInQuad = outInQuad,
  inCubic =
      inCubic,
  outCubic = outCubic,
  inOutCubic = inOutCubic,
  outInCubic = outInCubic,
  inQuart = inQuart,
  outQuart = outQuart,
  inOutQuart =
      inOutQuart,
  outInQuart = outInQuart,
  inQuint = inQuint,
  outQuint = outQuint,
  inOutQuint = inOutQuint,
  outInQuint =
      outInQuint,
  inSine = inSine,
  outSine = outSine,
  inOutSine = inOutSine,
  outInSine = outInSine,
  inExpo = inExpo,
  outExpo =
      outExpo,
  inOutExpo = inOutExpo,
  outInExpo = outInExpo,
  inCirc = inCirc,
  outCirc = outCirc,
  inOutCirc = inOutCirc,
  outInCirc =
      outInCirc,
  inElastic = inElastic,
  outElastic = outElastic,
  inOutElastic = inOutElastic,
  outInElastic = outInElastic,
  inBack =
      inBack,
  outBack = outBack,
  inOutBack = inOutBack,
  outInBack = outInBack,
  inBounce = inBounce,
  outBounce = outBounce,
  inOutBounce =
      inOutBounce,
  outInBounce = outInBounce,
  squashAndStretch = squashAndStretch
}

-- private stuff

local function copyTables(destination, keysTable, valuesTable, seen)
  valuesTable = valuesTable or keysTable
  seen        = seen or {} -- cycle guard
  if seen[keysTable] then return seen[keysTable] end
  seen[keysTable] = destination

  local mt = getmetatable(keysTable)
  if mt and getmetatable(destination) == nil then
    setmetatable(destination, mt)
  end

  for k, v in pairs(keysTable) do
    local srcVal = valuesTable and valuesTable[k]

    if vec2.isVector(v) then
      destination[k] = (srcVal or v):clone()
    elseif type(v) == "table" then
      destination[k] = copyTables({}, v, srcVal, seen)
    elseif k == "children" and Element and Element.isElement(destination) then
      -- leave original children table untouched
      destination[k] = destination[k] or {}
    else
      destination[k] = srcVal
    end
  end
  return destination
end

-- Validation with vec2 support
local function checkSubjectAndTargetRecursively(subject, target, path)
  path = path or {}
  for k, targetValue in pairs(target) do
    local newPath = copyTables({}, path)
    table.insert(newPath, tostring(k))
    local subjectValue = subject[k]
    if type(targetValue) == 'number' then
      assert(type(subjectValue) == 'number', "Parameter '" .. table.concat(newPath, '/') .. "' must be a number")
    elseif vec2.isVector(targetValue) then
      assert(vec2.isVector(subjectValue), "Parameter '" .. table.concat(newPath, '/') .. "' must be a Vector2")
    elseif type(targetValue) == 'table' then
      assert(type(subjectValue) == 'table' or type(subjectValue) == 'userdata',
        "Parameter '" .. table.concat(newPath, '/') .. "' must be a table (got " .. type(subjectValue) .. ")")
      checkSubjectAndTargetRecursively(subjectValue, targetValue, newPath)
    else
      error("Parameter '" .. table.concat(newPath, '/') .. "' must be a number, vec2, or table of those")
    end
  end
end

local function checkNewParams(duration, subject, target, easing)
  assert(type(duration) == 'number' and duration > 0, "duration must be a positive number")
  assert(type(subject) == 'table' or type(subject) == 'userdata', "subject must be a table or userdata")
  assert(type(target) == 'table', "target must be a table")
  assert(type(easing) == 'function', "easing must be a function")
  checkSubjectAndTargetRecursively(subject, target)
end

local function getEasingFunction(easing)
  easing = easing or "linear"
  if type(easing) == 'string' then
    easing = tween.easing[easing]
    if type(easing) ~= 'function' then
      error("Invalid easing function")
    end
  end
  return easing
end

-- Easing for numbers and vec2s
local function performEasingOnSubject(subject, target, initial, clock, duration, easing)
  local needs_dirty = false

  for k, v in pairs(target) do
    if type(v) == 'table' then
      performEasingOnSubject(subject[k], v, initial[k], clock, duration, easing)
      -- mark dirty for nested properties that affect layout
      if k == "position" or k == "size" or k == "anchor" then
        needs_dirty = true
      end
    elseif vec2.isVector(v) then
      local start = initial[k]
      local delta = v - start
      local t = easing(clock, 0, 1, duration)
      local new_value = start + delta * t
      subject[k]:replace(new_value)
      needs_dirty = true
    else
      local b, c, d = initial[k], v - initial[k], duration
      subject[k] = easing(clock, b, c, d)
      needs_dirty = true
    end
  end

  -- if this is an element and we changed properties, mark it dirty
  if needs_dirty and subject.mark_dirty and type(subject.mark_dirty) == "function" then
    subject:mark_dirty()
  end
end

-- Tween class
local Tween = {}
local Tween_mt = { __index = Tween }

---@param clock number
---@return boolean finished
function Tween:set(clock)
  assert(type(clock) == "number", "clock must be a number")

  -- Save the very first initial/target so we can restart cleanly on each loop
  if not self._initial0 then
    self.initial   = self.initial or copyTables({}, self.target, self.subject)
    self._initial0 = copyTables({}, self.initial)
    self._target0  = copyTables({}, self.target)
    -- In case constructor didn't set these:
    if self.loop ~= nil and self._loopsLeft == nil then
      self._loopsLeft = type(self.loop) == "number" and self.loop or (self.loop and math.huge or 0)
    end
  end

  self.clock = clock

  local finished = false

  if self.clock <= 0 then
    self.clock = 0
    copyTables(self.subject, self.initial)
  elseif self.clock >= self.duration then
    -- End of this leg
    if self.reverses then
      if not self._reversed then
        -- Finished forward leg, go backward
        self.clock = self.duration
        copyTables(self.subject, self.target)
        self._reversed = true
        self.target, self.initial = self.initial, self.target
        self.clock = 0
      else
        -- Finished backward leg -> full cycle done
        self.clock = self.duration
        copyTables(self.subject, self.target)

        if self._loopsLeft > 0 and self._loopsLeft ~= math.huge then
          self._loopsLeft = self._loopsLeft - 1
        end

        if self._loopsLeft ~= 0 then
          -- Restart forward leg
          self._reversed = false
          self.initial   = copyTables({}, self._initial0)
          self.target    = copyTables({}, self._target0)
          copyTables(self.subject, self.initial)
          self.clock = 0
        else
          finished = true
        end
      end
    else
      -- No reversing: one leg per cycle
      self.clock = self.duration
      copyTables(self.subject, self.target)

      if self._loopsLeft > 0 and self._loopsLeft ~= math.huge then
        self._loopsLeft = self._loopsLeft - 1
      end

      if self._loopsLeft ~= 0 then
        -- Restart from beginning
        self.initial = copyTables({}, self._initial0)
        self.target  = copyTables({}, self._target0)
        copyTables(self.subject, self.initial)
        self.clock = 0
      else
        finished = true
      end
    end
  else
    -- Normal in-between update
    performEasingOnSubject(self.subject, self.target,
      self.initial, self.clock,
      self.duration, self.easing)
  end


  return finished
end

function Tween:reset()
  ---@return boolean
  return self:set(0)
end

---@param dt number
---@return boolean finished
function Tween:update(dt)
  assert(type(dt) == 'number', "dt must be a number")
  return self:set(self.clock + dt)
end

function Tween:destroy()
  local gtable = tween.alltweens[self.pausable and "pausable" or "unpausable"]
  for i, t in ipairs(gtable) do
    if t == self then
      table.remove(gtable, i)
      break
    end
  end
end

-- Public API

---@param duration number
---@param subject table|Element|userdata
---@param target table
---@param gEasing? EasingName|EasingFunction
---@param args? TweenArgs
---@return Tween
function tween.new(duration, subject, target, gEasing, args)
  args              = args or {}
  args.pausable     = args.pausable
  args.completeFunc = args.completeFunc or function() end
  args.constFunc    = args.constFunc or function() end
  args.drawFunc     = args.drawFunc or function() end
  args.reverses     = args.reverses or false
  args.loop         = args.loop or false

  local neweasing   = getEasingFunction(gEasing)

  checkNewParams(duration, subject, target, neweasing)

  local obj = setmetatable({
    duration     = duration,
    subject      = subject,
    target       = target,
    easing       = neweasing,
    clock        = 0,
    pausable     = args.pausable,
    completeFunc = args.completeFunc,
    constFunc    = args.constFunc,
    drawFunc     = args.drawFunc,
    reverses     = args.reverses,
    loop         = args.loop,
    _loopsLeft   = (type(args.loop) == "number" and args.loop or (args.loop and math.huge or 0)),
    _reversed    = false
  }, Tween_mt)

  -- reduced motion: interface tweens snap to their target instead of animating
  if args.interface and CFG and CFG.getSetting then
    local reduced = CFG:getSetting('reduced_motion')
    if reduced and reduced.value then
      copyTables(obj.subject, obj.target)
      obj.clock = obj.duration
      obj._loopsLeft = 0
      if type(obj.subject) == 'table' and type(obj.subject.mark_dirty) == 'function' then
        obj.subject:mark_dirty()
      end
      obj.completeFunc()
      return obj
    end
  end

  table.insert(tween.alltweens[obj.pausable and "pausable" or "unpausable"], obj)
  return obj
end

---@param groupName 'pausable'|'unpausable'
---@param dt number
function tween.update(groupName, dt)
  assert(groupName == 'pausable' or groupName == 'unpausable', "groupName must be 'pausable' or 'unpausable'")
  assert(type(dt) == 'number', "dt must be a number")
  local list = tween.alltweens[groupName]
  local remove = {}
  for i, obj in ipairs(list) do
    obj.constFunc()
    if obj:update(dt) then
      if obj.completeFunc then
        obj.completeFunc()
      end
      table.insert(remove, i)
    end
  end
  for i = #remove, 1, -1 do
    table.remove(list, remove[i])
  end
end

---@param groupName 'pausable'|'unpausable'
function tween.draw(groupName)
  assert(groupName == 'pausable' or groupName == 'unpausable', "groupName must be 'pausable' or 'unpausable'")
  local list = tween.alltweens[groupName]
  for _, obj in ipairs(list) do
    obj.drawFunc()
  end
end
