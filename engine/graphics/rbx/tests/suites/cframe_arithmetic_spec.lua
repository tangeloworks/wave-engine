local suite = {}
local h = require("engine/graphics/rbx/tests/harness")
h.runtime_require("common.lua"); h.runtime_require("scene.lua")
local C = h.env.CFrame
local names = {"x","y","z","r00","r01","r02","r10","r11","r12","r20","r21","r22"}

-- Independent row/column oracle. It never invokes the runtime multiplication
-- operator or Angles constructor, and retains the specified left association.
local function product(a, b)
    local out = {}
    for row = 0, 2 do
        local first = 4 + row * 3
        out[row + 1] = a[row + 1] + a[first] * b[1] + a[first + 1] * b[2] + a[first + 2] * b[3]
        for column = 0, 2 do
            out[first + column] = a[first] * b[4 + column]
                + a[first + 1] * b[7 + column] + a[first + 2] * b[10 + column]
        end
    end
    return out
end

local function axes(rx, ry, rz)
    rx, ry, rz = tonumber(rx) or 0, tonumber(ry) or 0, tonumber(rz) or 0
    local sx, cx = math.sin(rx), math.cos(rx)
    local sy, cy = math.sin(ry), math.cos(ry)
    local sz, cz = math.sin(rz), math.cos(rz)
    return {0,0,0, 1,0,0, 0,cx,-sx, 0,sx,cx},
        {0,0,0, cy,0,sy, 0,1,0, -sy,0,cy},
        {0,0,0, cz,-sz,0, sz,cz,0, 0,0,1}
end

local function frame(values) return C.new(unpack(values, 1, 12)) end
local function components(value)
    local out = {}
    for index, name in ipairs(names) do out[index] = value[name] end
    return out
end
local function expect_exact(actual, expected, label, classify_nan)
    for index, name in ipairs(names) do
        local got, want = actual[name], expected[index]
        local matches
        if classify_nan and want ~= want then matches = got ~= got
        else matches = love.data.pack("string", "<d", got) == love.data.pack("string", "<d", want) end
        assert(matches, (label or "CFrame") .. "/" .. name .. ": " .. tostring(got) .. " expected " .. tostring(want))
    end
end

function suite.run(t)
    t.it("keeps every Angles lane bit-exact against independent literal Rx * Ry * Rz products", function()
        local negative_zero = -1 / math.huge
        local values = {0,negative_zero,.125,-.37,1.2345,-2.716,math.pi/2,-math.pi/2,
            math.pi,-math.pi,2*math.pi,-2*math.pi,1e-300,-1e-300,1e100,-1e100,1e308,-1e308}
        for index = 0, 383 do
            local rx = values[index % #values + 1]
            local ry = values[(index * 7 + math.floor(index / #values)) % #values + 1]
            local rz = values[(index * 11 + math.floor(index / 7)) % #values + 1]
            local x, y, z = axes(rx, ry, rz)
            local expected = product(product(x, y), z)
            expect_exact(C.Angles(rx, ry, rz), expected, "Angles/" .. index)
            expect_exact((frame(x) * frame(y)) * frame(z), expected, "literal product/" .. index)
        end
    end)
    t.it("retains coercion, signed zero and nonfinite propagation in all twelve Angles lanes", function()
        local nan, negative_zero = 0 / 0, -1 / math.huge
        local rows = {{}, {false,true,"not a number"}, {".125","-0","1e2"}, {nil,.25,nil},
            {negative_zero,negative_zero,negative_zero}, {nan,0,0}, {0,nan,0}, {0,0,nan},
            {math.huge,.2,-.3}, {.3,-math.huge,.7}, {.2,.3,math.huge},
            {-math.huge,math.huge,-math.huge}, {nan,-nan,nan}}
        for index, row in ipairs(rows) do
            local x, y, z = axes(unpack(row, 1, 3))
            local expected = product(product(x, y), z)
            local actual = C.Angles(unpack(row, 1, 3))
            local literal = (frame(x) * frame(y)) * frame(z)
            -- NaN encoding differs between scalar code and the operator route
            -- even in the original runtime. Pin its classification independently,
            -- then require exact bytes against the original literal operator route.
            expect_exact(actual, expected, "special Angles/" .. index, true)
            expect_exact(literal, expected, "special literal/" .. index, true)
            expect_exact(actual, components(literal), "special operator bytes/" .. index)
        end
        local x, y, z = axes(math.huge,0,0)
        local expected = product(product(x,y),z)
        assert(expected[2] ~= expected[2], "oracle failed to retain nonfinite translation propagation")
    end)
    t.it("keeps arbitrary frame products bit-exact without reassociating cancellation or zero terms", function()
        local nan, negative_zero = 0 / 0, -1 / math.huge
        local cases = {
            {{1,2,3, 1,0,0, 0,1,0, 0,0,1}, {4,-5,6, 1,0,0, 0,1,0, 0,0,1}},
            {{1,5,-7, 1e16,1,-1e16, .3,-.7,1.2, -2,.5,3},
                {1,1,1, 1,.1,-.2, 1,2,-3, 1,.7,-.8}},
            {{negative_zero,negative_zero,negative_zero, negative_zero,0,0, 0,negative_zero,0, 0,0,negative_zero},
                {negative_zero,0,negative_zero, -1,0,0, 0,-1,0, 0,0,-1}},
            {{1e300,-1e300,1e-300, 1e200,-1e200,1e-200, 1e-200,1e200,-1e200, -1e200,1e-200,1e200},
                {1e200,1e-200,-1e200, 1e200,1e-200,-1e200, 1e-200,-1e200,1e200, -1e200,1e200,1e-200}},
            {{nan,math.huge,-math.huge, nan,0,1, 1,-math.huge,0, 0,1,math.huge},
                {0,negative_zero,1, 1,0,nan, 0,1,0, math.huge,0,1}},
        }
        assert(product(cases[2][1],cases[2][2])[1] == 0,
            "cancellation oracle no longer evaluates translation from left to right")
        for index, row in ipairs(cases) do
            expect_exact(frame(row[1]) * frame(row[2]), product(row[1],row[2]), "arbitrary product/" .. index, true)
        end
        for index = 1, 256 do
            local a, b = {}, {}
            for lane = 1, 12 do
                a[lane] = math.sin(index*.13+lane*.21) * (lane%3+1)
                b[lane] = math.cos(index*.27-lane*.17) * (lane%4+1)
            end
            expect_exact(frame(a)*frame(b),product(a,b),"dense product/" .. index)
        end
    end)
    t.it("honors replaced multiplication and protected metatables in Angles", function()
        local original_mul, original_protection = C.__mul, C.__metatable
        local ok, err = xpcall(function()
            local count, sentinel = 0, C.new(17,23,29)
            C.__mul = function(a, b)
                count = count + 1
                if count == 2 then return sentinel end
                return original_mul(a,b)
            end
            assert(rawequal(C.Angles(.4,-.8,1.2),sentinel) and count==2,
                "Angles bypassed the public multiplication override")
            C.__mul = nil
            assert(not pcall(C.Angles,.4,-.8,1.2),"Angles ignored a missing multiplication operator")
            C.__mul = original_mul
            C.__metatable = "protected frame"
            local worked, message = pcall(C.Angles,.4,-.8,1.2)
            assert(not worked and tostring(message):find("left operand must be CFrame",1,true),
                "Angles bypassed the multiplication metatable check")
        end, debug.traceback)
        C.__mul, C.__metatable = original_mul, original_protection
        assert(ok, err)
    end)
    t.it("returns independent immutable frames and leaves retained inputs unchanged", function()
        local x,y,z = axes(.4,-.8,1.2)
        local expected = product(product(x,y),z)
        local a, b = C.Angles(.4,-.8,1.2), C.Angles(.4,-.8,1.2)
        assert(not rawequal(a,b) and getmetatable(a)==C and getmetatable(b)==C)
        assert(not pcall(function() a.r00=99 end),"Angles result became mutable")
        local result = a*b
        assert(not rawequal(result,a) and not rawequal(result,b))
        for index=1,32 do C.Angles(index*.1,-index*.3,index*.7) end
        expect_exact(a,expected,"retained first")
        expect_exact(b,expected,"retained second")
        expect_exact(result,product(expected,expected),"retained product")
    end)
end
return suite
