-- Minimal test framework for the RBX runtime suite.
--
-- Deliberately dependency-free: it runs inside LOVE with the graphics module
-- disabled, so it cannot use anything from engine/ that touches love.graphics.
--
-- The `known_bug` variant is the important one for this codebase. Stage 1 of the
-- rebuild requires regression tests to exist BEFORE behaviour changes, so an
-- audit finding is encoded as a test asserting the CORRECT Roblox behaviour and
-- registered with `known_bug`. While the defect is present the runner reports
-- KNOWN-BUG (not a failure, so the suite stays green and usable); once the fix
-- lands the assertion passes and the runner reports FIXED and fails the run,
-- forcing the test to be promoted to a normal `it`. That way neither a
-- regression nor a silent fix can go unnoticed.

local framework = {}

local RED = "\27[31m"
local GREEN = "\27[32m"
local YELLOW = "\27[33m"
local BLUE = "\27[36m"
local DIM = "\27[2m"
local RESET = "\27[0m"

-- LOVE's Windows console honours ANSI only on newer terminals; strip when piped.
local use_color = os.getenv("RBX_TEST_NO_COLOR") == nil
local function c(code, text)
    if not use_color then return text end
    return code .. text .. RESET
end

framework.results = {
    passed = 0,
    failed = 0,
    known_bug = 0,
    fixed = 0,
    skipped = 0,
    failures = {},
    fixed_list = {},
}

local current_suite = nil

---------------------------------------------------------------- assertions

local Expect = {}
Expect.__index = Expect

local function fmt(v)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" then
        if v ~= v then return "nan" end
        if v == math.huge then return "inf" end
        if v == -math.huge then return "-inf" end
        -- keep enough precision to see coordinate/transform drift
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
        return string.format("%.9g", v)
    end
    if t == "table" then
        local parts = {}
        local n = 0
        for k, val in pairs(v) do
            n = n + 1
            if n > 8 then parts[#parts + 1] = "..." break end
            parts[#parts + 1] = tostring(k) .. "=" .. (type(val) == "table" and "{...}" or tostring(val))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v)
end
framework.fmt = fmt

function Expect:to_be(expected)
    if self.value ~= expected then
        error(string.format("expected %s, got %s", fmt(expected), fmt(self.value)), 2)
    end
end

function Expect:to_not_be(expected)
    if self.value == expected then
        error(string.format("expected value to differ from %s", fmt(expected)), 2)
    end
end

function Expect:to_be_near(expected, tolerance)
    tolerance = tolerance or 1e-6
    local got = self.value
    if type(got) ~= "number" then
        error(string.format("expected a number near %s, got %s", fmt(expected), fmt(got)), 2)
    end
    if got ~= got then
        error(string.format("expected %s (+/- %s), got nan", fmt(expected), fmt(tolerance)), 2)
    end
    if math.abs(got - expected) > tolerance then
        error(string.format("expected %s (+/- %s), got %s  [delta %s]",
            fmt(expected), fmt(tolerance), fmt(got), fmt(got - expected)), 2)
    end
end

function Expect:to_be_truthy()
    if not self.value then
        error(string.format("expected a truthy value, got %s", fmt(self.value)), 2)
    end
end

function Expect:to_be_falsy()
    if self.value then
        error(string.format("expected a falsy value, got %s", fmt(self.value)), 2)
    end
end

function Expect:to_be_nil()
    if self.value ~= nil then
        error(string.format("expected nil, got %s", fmt(self.value)), 2)
    end
end

function Expect:to_be_type(expected)
    if type(self.value) ~= expected then
        error(string.format("expected type %s, got %s (%s)", expected, type(self.value), fmt(self.value)), 2)
    end
end

-- Vector-ish comparison that accepts {x,y,z}, {X,Y,Z} or {[1],[2],[3]}.
local function vec_components(v)
    if type(v) ~= "table" then return nil end
    local x = v.x or v.X or v[1]
    local y = v.y or v.Y or v[2]
    local z = v.z or v.Z or v[3]
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
    return x, y, z
end
framework.vec_components = vec_components

function Expect:to_be_vec_near(ex, ey, ez, tolerance)
    tolerance = tolerance or 1e-6
    local x, y, z = vec_components(self.value)
    if not x then
        error(string.format("expected a vector-like value, got %s", fmt(self.value)), 2)
    end
    if math.abs(x - ex) > tolerance or math.abs(y - ey) > tolerance or math.abs(z - ez) > tolerance then
        error(string.format("expected (%s, %s, %s) +/- %s, got (%s, %s, %s)",
            fmt(ex), fmt(ey), fmt(ez), fmt(tolerance), fmt(x), fmt(y), fmt(z)), 2)
    end
end

function Expect:to_be_finite()
    local v = self.value
    if type(v) ~= "number" then
        error(string.format("expected a finite number, got %s", fmt(v)), 2)
    end
    if v ~= v then error("expected a finite number, got nan", 2) end
    if v == math.huge or v == -math.huge then
        error("expected a finite number, got " .. fmt(v), 2)
    end
end

function Expect:to_contain(needle)
    if type(self.value) == "string" then
        if not string.find(self.value, needle, 1, true) then
            error(string.format("expected %s to contain %s", fmt(self.value), fmt(needle)), 2)
        end
        return
    end
    if type(self.value) == "table" then
        for _, v in pairs(self.value) do
            if v == needle then return end
        end
        error(string.format("expected table to contain %s", fmt(needle)), 2)
    end
    error(string.format("expected a string or table, got %s", fmt(self.value)), 2)
end

function Expect:to_error(pattern)
    if type(self.value) ~= "function" then
        error("expect(...):to_error() needs a function", 2)
    end
    local ok, err = pcall(self.value)
    if ok then
        error("expected the call to raise, but it returned normally", 2)
    end
    if pattern and not string.find(tostring(err), pattern, 1, true) then
        error(string.format("expected error containing %s, got %s", fmt(pattern), fmt(tostring(err))), 2)
    end
end

function framework.expect(value)
    return setmetatable({ value = value }, Expect)
end

-- Free-standing assert with a message, for conditions that read better inline.
function framework.assert_that(condition, message, ...)
    if not condition then
        error(select("#", ...) > 0 and string.format(message, ...) or message, 2)
    end
end

---------------------------------------------------------------- registration

function framework.describe(name, fn)
    current_suite = name
    print(c(BLUE, "\n  " .. name))
    local ok, err = pcall(fn)
    if not ok then
        framework.results.failed = framework.results.failed + 1
        framework.results.failures[#framework.results.failures + 1] = {
            suite = name,
            name = "<suite body>",
            err = tostring(err),
        }
        print("    " .. c(RED, "SUITE ERROR") .. " " .. tostring(err))
    end
    current_suite = nil
end

local function run_case(name, fn)
    local ok, err = pcall(fn)
    return ok, err
end

function framework.it(name, fn)
    local ok, err = run_case(name, fn)
    if ok then
        framework.results.passed = framework.results.passed + 1
        print("    " .. c(GREEN, "pass") .. " " .. name)
    else
        framework.results.failed = framework.results.failed + 1
        framework.results.failures[#framework.results.failures + 1] = {
            suite = current_suite, name = name, err = tostring(err),
        }
        print("    " .. c(RED, "FAIL") .. " " .. name)
        print("      " .. c(DIM, tostring(err)))
    end
end

-- `reference` should cite the audit finding, e.g. "binary.lua:843 PhysicalProperties".
function framework.known_bug(reference, name, fn)
    local ok, err = run_case(name, fn)
    if ok then
        -- The defect is gone. That is good news, but the test must be promoted
        -- so it protects the fix from here on -- so this fails the run loudly.
        framework.results.fixed = framework.results.fixed + 1
        framework.results.fixed_list[#framework.results.fixed_list + 1] = {
            suite = current_suite, name = name, reference = reference,
        }
        print("    " .. c(YELLOW, "FIXED") .. " " .. name)
        print("      " .. c(DIM, "known_bug now passes (" .. reference .. ") -- promote it to it()"))
    else
        framework.results.known_bug = framework.results.known_bug + 1
        print("    " .. c(YELLOW, "known-bug") .. " " .. name .. c(DIM, "  [" .. reference .. "]"))
        -- Show WHY it still fails. Without this a known_bug that is failing for a
        -- NEW reason -- or because the test itself is wrong -- looks identical to one
        -- failing for the original defect, which hides real information while a fix
        -- is being worked on. Set RBX_TEST_QUIET_KNOWN_BUGS=1 to suppress.
        if os.getenv("RBX_TEST_QUIET_KNOWN_BUGS") == nil then
            print("      " .. c(DIM, tostring(err)))
        end
    end
end

function framework.skip(name, reason)
    framework.results.skipped = framework.results.skipped + 1
    print("    " .. c(DIM, "skip") .. " " .. name .. c(DIM, "  (" .. (reason or "no reason given") .. ")"))
end

---------------------------------------------------------------- reporting

function framework.report()
    local r = framework.results
    print("")
    print(string.rep("-", 72))

    if #r.failures > 0 then
        print(c(RED, "FAILURES"))
        for _, f in ipairs(r.failures) do
            print(string.format("  %s > %s", tostring(f.suite), f.name))
            print("    " .. c(DIM, f.err))
        end
        print("")
    end

    if #r.fixed_list > 0 then
        print(c(YELLOW, "KNOWN BUGS THAT NOW PASS -- promote these to it()"))
        for _, f in ipairs(r.fixed_list) do
            print(string.format("  %s > %s   [%s]", tostring(f.suite), f.name, f.reference))
        end
        print("")
    end

    local total = r.passed + r.failed + r.known_bug + r.fixed
    print(string.format("%s  %d passed, %d failed, %d known-bug, %d newly-fixed, %d skipped  (%d total)",
        (r.failed == 0 and r.fixed == 0) and c(GREEN, "OK  ") or c(RED, "FAIL"),
        r.passed, r.failed, r.known_bug, r.fixed, r.skipped, total))
    print(string.rep("-", 72))

    return (r.failed == 0 and r.fixed == 0)
end

return framework
