-- rotatev joint: kinematic motor spinning part1 about c0's local +z, repositioned each frame, never detaches
-- rate: constant=paramb, sin=parama*sin(t*paramb), placement p1=p0*c0*rz(angle)*c1^-1

local CFrameMath = runtime_require("physics/cframe_math.lua")
local JointFrames = runtime_require("physics/joint_frames.lua")

local DynamicRotate = {}

local sin = math.sin
local cos = math.cos
local TWO_PI = math.pi * 2

DynamicRotate.NO_INPUT = 0
DynamicRotate.CONSTANT = 11
DynamicRotate.SIN      = 12

-- bounds so a malformed map cant nan/inf
local MAX_RATE = 50               -- rad/s cap, no tunneling at 1/60
local DEFAULT_CONSTANT_RATE = 1.0 -- rad/s, constant input w/ no paramb

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function clamp_rate(r)
    if not finite(r) then return 0 end
    if r > MAX_RATE then return MAX_RATE end
    if r < -MAX_RATE then return -MAX_RATE end
    return r
end

-- rad, about local +z (the axle)
local function Rz(angle)
    local c, s = cos(angle), sin(angle)
    return CFrameMath.pack(0, 0, 0, c, -s, 0, s, c, 0, 0, 0, 1)
end

-- opts: input_type/param_a/param_b/base_angle, face/p0_rest/p1_rest for rest-relative
-- rest-relative fixes flip: angle=base reproduces authored pose exactly, no rest pose = absolute fallback
function DynamicRotate.make_follower(part0, part1, c0, c1, opts)
    opts = opts or {}
    local base = tonumber(opts.base_angle) or 0
    if not finite(base) then base = 0 end
    -- caller rest pose survives rebuild, else read live
    local p0_rest = opts.p0_rest
        or ((type(part0.CFrame) == "table") and CFrameMath.pack(CFrameMath.unpack(part0.CFrame))) or nil
    local p1_rest = opts.p1_rest
        or ((type(part1.CFrame) == "table") and CFrameMath.pack(CFrameMath.unpack(part1.CFrame))) or nil
    local rel = (p0_rest ~= nil and p1_rest ~= nil)
        and CFrameMath.mul(CFrameMath.inv(p0_rest), p1_rest) or nil
    -- axle in part0-local, +z = spin axis
    local axle
    if opts.face then
        local sz = part0.Size
        axle = JointFrames.face_basis(opts.face,
            sz and (sz.x or sz.X) or nil, sz and (sz.y or sz.Y) or nil, sz and (sz.z or sz.Z) or nil)
    elseif c0 ~= nil then
        axle = CFrameMath.orthonormalize_rot(c0)
    else
        axle = CFrameMath.identity()
    end
    return {
        part0 = part0, part1 = part1,
        c0 = c0, c1 = c1,
        rel = rel,
        axle = axle,
        axle_inv = CFrameMath.inv(axle),
        input_type = tonumber(opts.input_type) or DynamicRotate.NO_INPUT,
        param_a = tonumber(opts.param_a),
        param_b = tonumber(opts.param_b),
        base_angle = base,
        angle = base,
    }
end

-- rad/s at sim time t
local function rate_of(rec, t)
    local it = rec.input_type
    if it == DynamicRotate.SIN then
        local a = rec.param_a or 0
        local b = rec.param_b or 0
        return clamp_rate(a * sin((tonumber(t) or 0) * b))
    elseif it == DynamicRotate.CONSTANT then
        local b = rec.param_b
        if b == nil then b = DEFAULT_CONSTANT_RATE end
        return clamp_rate(b)
    end
    return 0  -- noinput/unknown: hold
end

-- advances by dt -> part1's new cframe, rest-relative if rest pose captured else absolute
function DynamicRotate.advance(rec, dt, t)
    local rate = rate_of(rec, t)
    local a = rec.angle + rate * (tonumber(dt) or 0)
    if not finite(a) then a = rec.base_angle or 0 end
    if a > 1e6 or a < -1e6 then a = a % TWO_PI end
    rec.angle = a
    if rec.rel ~= nil then
        -- part1 = p0_now * a * rz(a-base) * a^-1 * rel
        local acc = CFrameMath.mul(rec.part0.CFrame, rec.axle)
        acc = CFrameMath.mul(acc, Rz(a - (rec.base_angle or 0)))
        acc = CFrameMath.mul(acc, rec.axle_inv)
        return CFrameMath.mul(acc, rec.rel)
    end
    return CFrameMath.motor6d_part1_cframe(rec.part0.CFrame, rec.c0, Rz(a), rec.c1)
end

return DynamicRotate
