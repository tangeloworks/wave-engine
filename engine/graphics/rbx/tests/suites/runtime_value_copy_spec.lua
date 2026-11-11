-- Value-copy compatibility, not a native Roblox serialization specification.
-- Explicit graph identities are the oracle; this suite does not reimplement
-- the copier or infer allocation savings from source shape/elapsed time.
local suite = {}

local function expect_flat_copy(t, copy, source)
    local out = copy(source)
    t.assert_that(out ~= source, "copy retained its source table")
    t.expect(getmetatable(out)):to_be(nil)
    local source_count, copied_count = 0, 0
    for key, value in pairs(source) do
        source_count = source_count + 1
        t.expect(out[key]):to_be(value)
    end
    for _ in pairs(out) do copied_count = copied_count + 1 end
    t.expect(copied_count):to_be(source_count)
    return out
end

function suite.run(t, harness)
    harness.runtime_require("common.lua")
    local copy = harness.env.copy_runtime_value
    t.assert_that(type(copy) == "function", "production copy_runtime_value is unavailable")

    t.describe("Runtime value-copy graph ownership", function()
        t.it("returns non-table values unchanged, including nonfinite numbers and signed zero", function()
            local fn = function() return "not called" end
            local thread = coroutine.create(fn)
            for _, value in ipairs({ false, true, 0, 17.25, -13, "", "text", math.huge, -math.huge, fn, thread }) do
                t.expect(copy(value)):to_be(value)
            end
            t.expect(copy(nil)):to_be(nil)
            local nan = copy(0 / 0)
            t.expect(nan ~= nan):to_be(true)
            t.expect(1 / copy(-1 / math.huge)):to_be(-math.huge)
            t.expect(coroutine.status(thread)):to_be("suspended")
            -- A real headless LÖVE Data object is also an opaque value, not a
            -- table whose memory the helper owns or clones.
            local data = love.data.newByteData(1)
            local ok, err = xpcall(function()
                t.expect(type(data)):to_be("userdata")
                t.expect(copy(data)):to_be(data)
                t.expect(data:getSize()):to_be(1)
            end, debug.traceback)
            data:release()
            if not ok then error(err, 0) end
        end)

        t.it("freshly copies empty, flat array, hash and mixed tables without changing keys or holes", function()
            local empty = {}
            local first, second = expect_flat_copy(t, copy, empty), expect_flat_copy(t, copy, empty)
            t.assert_that(first ~= second, "independent empty copies share storage")
            expect_flat_copy(t, copy, { 1, false, 3, "four" })
            expect_flat_copy(t, copy, { value = 17, enabled = false, name = "Marker", empty = "" })
            local fn = function() end
            local mixed = { [0] = "zero", [1] = "one", [3] = "three", [-2] = false,
                [false] = "boolean key", [fn] = "function key", named = fn }
            local out = expect_flat_copy(t, copy, mixed)
            t.expect(rawget(out, 2)):to_be(nil)
            out[1] = "changed"
            t.expect(mixed[1]):to_be("one")
        end)

        t.it("uses caller memo hits verbatim but treats false entries and false memo arguments as misses", function()
            local source, leaf = { marker = 17 }, { value = 23 }
            source.leaf = leaf
            local sentinel = { caller_owned = true }
            local memo = { [source] = sentinel }
            t.expect(copy(source, memo)):to_be(sentinel)
            t.expect(sentinel.leaf):to_be(nil)
            t.expect(memo[leaf]):to_be(nil)
            memo[source] = 0 -- Lua truthiness, not a table-only cache contract.
            t.expect(copy(source, memo)):to_be(0)
            memo[source] = "caller sentinel"
            t.expect(copy(source, memo)):to_be("caller sentinel")
            memo[source], memo[leaf] = false, false
            local out = copy(source, memo)
            t.assert_that(out ~= source and out.leaf ~= leaf, "false memo entry bypassed owned copy")
            t.expect(memo[source]):to_be(out)
            t.expect(memo[leaf]):to_be(out.leaf)
            t.expect(copy(source, memo)):to_be(out)
            local without_memo = copy(source, false)
            t.assert_that(without_memo ~= out and without_memo.leaf ~= out.leaf,
                "false memo argument reused another call's copies")
        end)

        t.it("honors a caller memo for flat roots, nested aliases and preexisting external replacements", function()
            local leaf, external = { marker = 17 }, { external = 23 }
            local source = { left = leaf, right = leaf }
            local memo = { [leaf] = external }
            local out = copy(source, memo)
            t.expect(memo[source]):to_be(out)
            t.expect(out.left):to_be(external)
            t.expect(out.right):to_be(external)
            local flat, flat_memo = { x = 1, y = 2 }, {}
            local flat_out = copy(flat, flat_memo)
            t.expect(flat_memo[flat]):to_be(flat_out)
            t.expect(copy(flat, flat_memo)):to_be(flat_out)
            local empty, empty_memo = {}, {}
            local empty_out = copy(empty, empty_memo)
            t.expect(empty_memo[empty]):to_be(empty_out)
        end)

        t.it("preserves shared flat and nested leaves while isolating source mutations", function()
            local leaf = { x = 1, y = 2 }
            local branch = { leaf = leaf, tag = "branch" }
            local source = { left = leaf, right = leaf, branch = branch, other_branch = branch }
            local out = copy(source)
            t.assert_that(out ~= source and out.left ~= leaf and out.branch ~= branch,
                "owned graph retained an original table")
            t.expect(out.left):to_be(out.right)
            t.expect(out.branch):to_be(out.other_branch)
            t.expect(out.branch.leaf):to_be(out.left)
            out.left.x, out.branch.tag = 99, "changed"
            t.expect(leaf.x):to_be(1)
            t.expect(branch.tag):to_be("branch")
            leaf.y = 77
            t.expect(out.left.y):to_be(2)
        end)

        t.it("closes self, mutual and parent cycles on copied nodes instead of originals", function()
            local source = { marker = 17 }
            local child = { marker = 23, parent = source }
            local other = { peer = child }
            source.self, source.child, source.alias = source, child, child
            child.peer = other
            local out = copy(source)
            t.assert_that(out ~= source and out.child ~= child and out.child.peer ~= other)
            t.expect(out.self):to_be(out)
            t.expect(out.alias):to_be(out.child)
            t.expect(out.child.parent):to_be(out)
            t.expect(out.child.peer.peer):to_be(out.child)
            out.marker = 101
            t.expect(source.marker):to_be(17)
            t.expect(child.parent):to_be(source)
        end)

        t.it("unifies direct and wrapped references to one source graph including wrapper backedges", function()
            local leaf = { value = 17 }
            local payload = { leaf = leaf, marker = "payload" }
            local first = { _surface_gui_data = payload, ignored = "first wrapper" }
            local second = { _surface_gui_data = payload, ignored = "second wrapper" }
            payload.back = first
            local source = { direct = payload, left = first, right = second, leaf = leaf }
            local out = copy(source)
            t.expect(out.direct):to_be(out.left)
            t.expect(out.left):to_be(out.right)
            t.expect(out.left.back):to_be(out.left)
            t.expect(out.left.leaf):to_be(out.leaf)
            t.expect(out.left.ignored):to_be(nil)
            t.expect(out.left._surface_gui_data):to_be(nil)
            t.assert_that(out.left ~= payload and out.leaf ~= leaf)
            out.leaf.value = 99
            t.expect(leaf.value):to_be(17)
            local memo, reused = {}, { caller_owned = true }
            memo[payload] = reused
            t.expect(copy(first, memo)):to_be(reused)
            t.expect(copy(second, memo)):to_be(reused)
            t.expect(rawget(memo, first)):to_be(nil)
            t.expect(rawget(memo, second)):to_be(nil)
        end)

        t.it("preserves raw single-hop wrapper semantics, false redirection and self wrappers", function()
            local payload = { marker = "payload" }
            local inner = { _surface_gui_data = payload, marker = "inner wrapper" }
            local outer = { _surface_gui_data = inner, marker = "outer wrapper" }
            local out = copy(outer)
            -- The selected source is inner. It is enumerated as-is, not
            -- recursively unwrapped before copying its own child values.
            t.expect(out.marker):to_be("inner wrapper")
            t.expect(out._surface_gui_data.marker):to_be("payload")
            t.assert_that(out ~= inner and out._surface_gui_data ~= payload)
            local disabled = { _surface_gui_data = false, marker = 17 }
            local disabled_out = copy(disabled)
            t.expect(disabled_out._surface_gui_data):to_be(false)
            t.expect(disabled_out.marker):to_be(17)
            local self_wrapper = { marker = 23 }
            self_wrapper._surface_gui_data = self_wrapper
            local self_out = copy(self_wrapper)
            t.expect(self_out._surface_gui_data):to_be(self_out)
            t.expect(self_out.marker):to_be(23)
        end)

        t.it("preserves existing errors for truthy non-table wrapper sources unless memoized", function()
            for _, target in ipairs({ true, 17, "not a source table" }) do
                local wrapper = { _surface_gui_data = target }
                local ok = pcall(copy, wrapper)
                t.expect(ok):to_be(false)
                local sentinel = {}
                t.expect(copy(wrapper, { [target] = sentinel })):to_be(sentinel)
            end
        end)

        t.it("keeps table keys by identity while copying the same tables when they are values", function()
            local key = { marker = "key" }
            local leaf = { value = 17 }
            local source = { [key] = leaf, key_as_value = key, leaf = leaf }
            local out = copy(source)
            t.expect(out[key]):to_be(out.leaf)
            t.assert_that(out.key_as_value ~= key and out.leaf ~= leaf)
            t.expect(out[out.key_as_value]):to_be(nil)
            t.expect(out.key_as_value.marker):to_be("key")
            out.key_as_value.marker = "copied key-as-value"
            t.expect(key.marker):to_be("key")
            local key_only_memo = {}
            local key_only = copy({ [key] = "scalar" }, key_only_memo)
            t.expect(key_only[key]):to_be("scalar")
            t.expect(key_only_memo[key]):to_be(nil)
        end)

        t.it("drops metatables without reading inherited fields or synthesizing redirected sources", function()
            local lookups = 0
            local source = setmetatable({ marker = 17, nested = { value = 23 } }, {
                __index = function(_, key)
                    lookups = lookups + 1
                    if key == "_surface_gui_data" then return { wrong_source = true } end
                    return "inherited"
                end,
                __newindex = function() error("source must not be written") end,
            })
            setmetatable(source.nested, { __index = { inherited = true } })
            local out = copy(source)
            t.expect(lookups):to_be(0)
            t.expect(getmetatable(out)):to_be(nil)
            t.expect(getmetatable(out.nested)):to_be(nil)
            t.expect(out.marker):to_be(17)
            t.expect(out.nested.value):to_be(23)
            t.expect(out.inherited):to_be(nil)
            t.expect(out.wrong_source):to_be(nil)
            t.expect(rawget(source, "_surface_gui_data")):to_be(nil)
        end)

        t.it("uses a shared caller memo across roots but isolates ordinary repeated and per-property copies", function()
            local leaf = { value = 17 }
            local first_source, second_source = { child = leaf }, { child = leaf }
            local shared_memo = {}
            local first, second = copy(first_source, shared_memo), copy(second_source, shared_memo)
            t.expect(first.child):to_be(second.child)
            t.expect(shared_memo[leaf]):to_be(first.child)
            local first_owned, second_owned = copy(first_source), copy(first_source)
            t.assert_that(first_owned ~= second_owned and first_owned.child ~= second_owned.child)
            local source_properties = { Left = leaf, Right = leaf }
            local property_copies = { Left = copy(source_properties.Left), Right = copy(source_properties.Right) }
            t.assert_that(property_copies.Left ~= property_copies.Right,
                "independent property copies acquired a cross-call alias")
            first_owned.child.value, property_copies.Left.value = 99, 101
            t.expect(second_owned.child.value):to_be(17)
            t.expect(property_copies.Right.value):to_be(17)
            t.expect(leaf.value):to_be(17)
        end)

        t.it("preserves arbitrary transport fields and their aliases without applying schema filters", function()
            local metadata = { marker = 17 }
            local source = { ClassName = "Unusual", Name = "Transport", MeshType = 65535,
                Scale = "malformed-but-preserved", scale = false, TextureId = "", CameraType = -1,
                properties = metadata, _dom_instance = metadata, Children = { metadata },
                CurrentCamera = "RBX99", UnknownProperty = metadata, [false] = metadata }
            source.Parent = source
            local out = copy(source)
            t.expect(out.ClassName):to_be("Unusual")
            t.expect(out.Name):to_be("Transport")
            t.expect(out.MeshType):to_be(65535)
            t.expect(out.Scale):to_be("malformed-but-preserved")
            t.expect(out.scale):to_be(false)
            t.expect(out.TextureId):to_be("")
            t.expect(out.CameraType):to_be(-1)
            t.expect(out.CurrentCamera):to_be("RBX99")
            t.expect(out.Parent):to_be(out)
            t.expect(out.properties):to_be(out._dom_instance)
            t.expect(out.properties):to_be(out.Children[1])
            t.expect(out.properties):to_be(out.UnknownProperty)
            t.expect(out.properties):to_be(out[false])
            t.assert_that(out.properties ~= metadata and out.Children ~= source.Children)
        end)

        t.it("records actual caller-memo writes once per copied source without claiming allocation counts", function()
            local leaf = { marker = 17 }
            local wrapped = { _surface_gui_data = leaf }
            local source = { left = leaf, right = wrapped }
            source.self = source
            local writes, values = {}, {}
            local memo = setmetatable({}, {
                __newindex = function(self, key, value)
                    writes[key] = (writes[key] or 0) + 1
                    values[key] = value
                    rawset(self, key, value)
                end,
            })
            local out = copy(source, memo)
            t.expect(out.self):to_be(out)
            t.expect(out.left):to_be(out.right)
            t.expect(writes[source]):to_be(1)
            t.expect(writes[leaf]):to_be(1)
            t.expect(writes[wrapped]):to_be(nil)
            t.expect(values[source]):to_be(out)
            t.expect(values[leaf]):to_be(out.left)
            local count = 0
            for _ in pairs(writes) do count = count + 1 end
            t.expect(count):to_be(2)
            t.expect(copy(source, memo)):to_be(out)
            t.expect(writes[source]):to_be(1)
            t.expect(writes[leaf]):to_be(1)
            -- This observes the public caller-supplied memo only. A plain Lua
            -- table literal allocation is not observable by this recorder.
        end)
    end)
end

return suite
