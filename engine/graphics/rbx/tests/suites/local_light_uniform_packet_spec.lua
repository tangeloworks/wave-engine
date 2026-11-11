-- Real-driver and failure-transaction coverage for the fixed local-light
-- uniform packet.  This suite intentionally uses LÖVE graphics: accepting a
-- Data object for a vec4 array is a driver-facing contract, not a mockable one.

local suite = {}

suite.needs_graphics = true

local ffi = require("ffi")

local RUNTIME_MODULES = {
    "common.lua",
    "gui.lua",
    "parser.lua",
    "scene.lua",
    "datamodel.lua",
    "geometry.lua",
    "assets.lua",
    "render.lua",
    "surface.lua",
    "lifecycle.lua",
}

local function release(resource)
    if resource and resource.release then
        pcall(resource.release, resource)
    end
end

local function compact_values(seed)
    local values = {}
    for index = 1, 96 do
        values[index] = seed + index * 0.001
    end
    return values
end

local function immutable_pack(key, count, ambient, seed)
    return {
        key = key,
        count = count,
        ambient = ambient,
        _compact_values = compact_values(seed or 0),
        _payload_immutable = true,
    }
end

local function new_packet_core(RBX, UniformPacket)
    local scratch, reason = UniformPacket.new()
    assert(scratch, reason)
    local noted_sends = 0
    local core = setmetatable({
        max_lights_per_batch = 4,
        _local_light_uniform_state = {},
        _local_light_uniform_support = {},
        _local_light_uniform_packet_scratch = scratch,
        _local_light_uniform_packet_available = true,
        _local_light_uniform_packet_allocation_count = 1,
        _local_light_uniform_packet_shader_support = {},
        _local_light_uniform_packet_shader_fallback_count = 0,
        _local_light_stats = {},
    }, RBX)
    core._note_uniform_send = function(_, count)
        noted_sends = noted_sends + (count or 1)
    end
    return core, scratch, function()
        return noted_sends
    end
end

local function payload_shader()
    return love.graphics.newShader([[
        extern vec4 uLocalLights[25];
        vec4 effect(
            vec4 color,
            Image texture,
            vec2 texture_coords,
            vec2 screen_coords
        ) {
            int column = int(floor(screen_coords.x));
            if (column == 0) {
                return vec4(uLocalLights[0].xyz,
                    uLocalLights[0].w * 0.25);
            }
            if (column == 1) return uLocalLights[1];
            if (column == 2) return uLocalLights[7];
            return uLocalLights[24];
        }
    ]])
end

local function draw_payload(shader, canvas)
    love.graphics.push("all")
    love.graphics.setCanvas(canvas)
    love.graphics.origin()
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.setBlendMode("replace", "premultiplied")
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setShader(shader)
    love.graphics.rectangle("fill", 0, 0, 4, 1)
    love.graphics.pop()
end

local function count_gated_shader()
    return love.graphics.newShader([[
        extern vec4 uLocalLights[25];
        vec4 effect(
            vec4 color,
            Image texture,
            vec2 texture_coords,
            vec2 screen_coords
        ) {
            float count = uLocalLights[0].w;
            vec4 sum = uLocalLights[0];
            if (count > 0.5) {
                sum += uLocalLights[1] + uLocalLights[2] + uLocalLights[3]
                    + uLocalLights[4] + uLocalLights[5] + uLocalLights[6];
            }
            if (count > 1.5) {
                sum += uLocalLights[7] + uLocalLights[8] + uLocalLights[9]
                    + uLocalLights[10] + uLocalLights[11] + uLocalLights[12];
            }
            if (count > 2.5) {
                sum += uLocalLights[13] + uLocalLights[14] + uLocalLights[15]
                    + uLocalLights[16] + uLocalLights[17] + uLocalLights[18];
            }
            if (count > 3.5) {
                sum += uLocalLights[19] + uLocalLights[20] + uLocalLights[21]
                    + uLocalLights[22] + uLocalLights[23] + uLocalLights[24];
            }
            return sum;
        }
    ]])
end

local function draw_count_gated(shader, canvas)
    love.graphics.push("all")
    love.graphics.setCanvas(canvas)
    love.graphics.origin()
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.setBlendMode("replace", "premultiplied")
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setShader(shader)
    love.graphics.rectangle("fill", 0, 0, 1, 1)
    love.graphics.pop()
end

function suite.run(t, harness)
    local expect = t.expect
    for _, module_name in ipairs(RUNTIME_MODULES) do
        harness.runtime_require(module_name)
    end
    local RBX = harness.env.RBX
    local UniformPacket = harness.runtime_require("uniform_packet.lua")

    t.describe("local-light uniform ByteData layout", function()
        t.it("preserves independent exact bytes through repeated immutable packs and count changes", function()
            local scratch = assert(UniformPacket.new())
            local pack = immutable_pack("bytes", 4, { -0.0, 0.25, 0.5 }, 0)
            for i = 1, 96 do pack._compact_values[i] = i / 8 end
            pack._compact_values[2] = 0 / 0
            pack._compact_values[3] = "0.75"
            pack._compact_values[25] = math.huge
            for _, count in ipairs({ 4, 4, 0, 0, 1, 1, 3, 3, 2, 2, 4, 4 }) do
                local expected = ffi.new("float[100]")
                expected[0], expected[1], expected[2], expected[3] = -0.0, 0.25, 0.5, count
                for i = 1, count * 24 do
                    expected[i + 3] = (i == 2 or i == 25) and 0
                        or (i == 3 and 0.75 or i / 8)
                end
                ffi.fill(scratch.pointer, 400, 0x7f)
                local sanitized, selected = UniformPacket.write_local_lights(scratch, pack, count)
                expect(selected):to_be(count)
                expect(sanitized):to_be(count == 0 and 0 or (count == 1 and 1 or 2))
                expect(scratch.data:getString()):to_be(ffi.string(expected, 400))
            end
            release(scratch.data)
        end)

        t.it("keeps serialization independent of scratch ownership and writable compatibility edits", function()
            local a, b = assert(UniformPacket.new()), assert(UniformPacket.new())
            local pack = immutable_pack("same-label", 1, { 0.125, 0.25, 0.5 }, 0)
            local other = immutable_pack("same-label", 1, { 0.75, 0.5, 0.25 }, 1)
            UniformPacket.write_local_lights(a, pack, 4)
            local original = a.data:getString()
            UniformPacket.write_local_lights(a, other, 4)
            t.assert_that(a.data:getString() ~= original, "different immutable payload shares no bytes")
            UniformPacket.write_local_lights(b, pack, 4)
            expect(b.data:getString()):to_be(original)
            release(a.data)
            ffi.fill(b.pointer, 400, 0x55)
            UniformPacket.write_local_lights(b, pack, 4)
            expect(b.data:getString()):to_be(original)
            -- Even a manually installed slots view must override compact data.
            pack.slots = { { a = { 0.875, 0, 0, 0 } } }
            UniformPacket.write_local_lights(b, pack, 4)
            local expected = ffi.new("float[100]")
            expected[0], expected[1], expected[2], expected[3], expected[4] = 0.125, 0.25, 0.5, 1, 0.875
            expect(b.data:getString()):to_be(ffi.string(expected, 400))
            pack._payload_immutable = false
            pack.slots[1].a[1] = 0.625
            UniformPacket.write_local_lights(b, pack, 4)
            expected[4] = 0.625
            expect(b.data:getString()):to_be(ffi.string(expected, 400))
            release(b.data)
        end)

        t.it("packs exactly 100 floats, sanitizes non-finite values, and reuses one allocation", function()
            local original_new_byte_data = love.data.newByteData
            local allocation_count = 0
            love.data.newByteData = function(...)
                allocation_count = allocation_count + 1
                return original_new_byte_data(...)
            end
            local scratch, reason = UniformPacket.new()
            local create_ok = scratch ~= nil
            love.data.newByteData = original_new_byte_data
            t.assert_that(create_ok, tostring(reason))

            local values = compact_values(1)
            values[5] = -math.huge
            values[24] = {}
            local pack = {
                count = 2,
                ambient = { 0.125, 0 / 0, math.huge, 0 },
                _compact_values = values,
            }
            local data = scratch.data
            local pointer = scratch.pointer
            local sanitized, selected =
                UniformPacket.write_local_lights(scratch, pack, 4)
            local floats = ffi.cast("const float *", data:getFFIPointer())

            expect(allocation_count):to_be(1)
            expect(data:getSize()):to_be(400)
            expect(sanitized):to_be(4)
            expect(selected):to_be(2)
            expect(tonumber(floats[0])):to_be(0.125)
            expect(tonumber(floats[1])):to_be(0)
            expect(tonumber(floats[2])):to_be(0)
            expect(tonumber(floats[3])):to_be(2)
            expect(tonumber(floats[4])):to_be_near(1.001, 1e-6)
            expect(tonumber(floats[8])):to_be(0)
            expect(tonumber(floats[27])):to_be(0)
            expect(tonumber(floats[28])):to_be_near(1.025, 1e-6)
            for index = 52, 99 do
                expect(tonumber(floats[index])):to_be(0)
            end

            UniformPacket.write_local_lights(scratch, {
                count = 0,
                ambient = { 0, 0, 0 },
            }, 4)
            expect(scratch.data):to_be(data)
            expect(scratch.pointer):to_be(pointer)
            expect(allocation_count):to_be(1)
            for index = 4, 99 do
                expect(tonumber(floats[index])):to_be(0)
            end
            release(data)
        end)

        t.it("makes a materialized writable slot view authoritative", function()
            local scratch, reason = UniformPacket.new()
            t.assert_that(scratch ~= nil, tostring(reason))
            local pack = immutable_pack(
                "materialized", 1, { 0.1, 0.2, 0.3, 0 }, 10)
            pack.slots = {
                {
                    a = { 0.91, 0.92, 0.93, 0.94 },
                    b = { 0.81, 0.82, 0.83, 0.84 },
                    c = { 0.71, 0.72, 0.73, 0.74 },
                    d = { 0.61, 0.62, 0.63, 0.64 },
                    e = { 0.51, 0.52, 0.53, 0.54 },
                    f = { 0.41, 0.42, 0.43, 0.44 },
                },
            }
            UniformPacket.write_local_lights(scratch, pack, 4)
            local floats = scratch.floats
            expect(tonumber(floats[4])):to_be_near(0.91, 1e-6)
            expect(tonumber(floats[8])):to_be_near(0.81, 1e-6)
            expect(tonumber(floats[24])):to_be_near(0.41, 1e-6)
            expect(tonumber(floats[28])):to_be(0)
            release(scratch.data)
        end)
    end)

    t.describe("local-light uniform packet GPU contract", function()
        t.it("is pixel-identical to the legacy vec4-array upload on LÖVE 11.5", function()
            local formats = love.graphics.getCanvasFormats()
            t.assert_that(formats.rgba16f == true,
                "rgba16f is required for the packet pixel oracle")
            local shader = payload_shader()
            local legacy_canvas = love.graphics.newCanvas(4, 1, {
                format = "rgba16f", readable = true, msaa = 0,
            })
            local packet_canvas = love.graphics.newCanvas(4, 1, {
                format = "rgba16f", readable = true, msaa = 0,
            })
            local scratch, reason = UniformPacket.new()
            t.assert_that(scratch ~= nil, tostring(reason))
            local pack = immutable_pack(
                "pixel-equality", 2, { 0.125, 0.25, 0.375, 0 }, 0)

            local legacy_args = {}
            for vector_index = 1, 25 do
                legacy_args[vector_index] = { 0, 0, 0, 0 }
            end
            legacy_args[1] = { 0.125, 0.25, 0.375, 2 }
            for component = 1, 48 do
                local vector_index = 2 + math.floor((component - 1) / 4)
                local vector_component = 1 + ((component - 1) % 4)
                legacy_args[vector_index][vector_component] =
                    pack._compact_values[component]
            end
            shader:send("uLocalLights", unpack(legacy_args))
            draw_payload(shader, legacy_canvas)

            UniformPacket.write_local_lights(scratch, pack, 4)
            -- This unprotected call is the API gate: a rejected Data-array
            -- signature fails the suite instead of silently testing fallback.
            UniformPacket.send_local_lights(shader, scratch)
            draw_payload(shader, packet_canvas)

            local legacy_pixels = legacy_canvas:newImageData()
            local packet_pixels = packet_canvas:newImageData()
            for x = 0, 3 do
                local lr, lg, lb, la = legacy_pixels:getPixel(x, 0)
                local pr, pg, pb, pa = packet_pixels:getPixel(x, 0)
                expect(pr):to_be_near(lr, 1e-6)
                expect(pg):to_be_near(lg, 1e-6)
                expect(pb):to_be_near(lb, 1e-6)
                expect(pa):to_be_near(la, 1e-6)
            end

            release(legacy_pixels)
            release(packet_pixels)
            release(scratch.data)
            release(legacy_canvas)
            release(packet_canvas)
            release(shader)
        end)

        t.it("sends only the active local-light prefix without exposing prior inactive slots", function()
            local full_shader = count_gated_shader()
            local prefix_shader = count_gated_shader()
            local full_canvas = love.graphics.newCanvas(1, 1, {
                format = "rgba16f", readable = true, msaa = 0,
            })
            local prefix_canvas = love.graphics.newCanvas(1, 1, {
                format = "rgba16f", readable = true, msaa = 0,
            })
            local full_scratch = assert(UniformPacket.new())
            local prefix_scratch = assert(UniformPacket.new())
            for index, count in ipairs({ 4, 0, 1, 3, 2, 4, 0 }) do
                local pack = immutable_pack(
                    "prefix-" .. tostring(index), count,
                    { index * 0.01, index * 0.02, index * 0.03 }, index * 10)
                local _, full_count = UniformPacket.write_local_lights(
                    full_scratch, pack, 4)
                local _, prefix_count = UniformPacket.write_local_lights(
                    prefix_scratch, pack, 4)
                expect(full_count):to_be(count)
                expect(prefix_count):to_be(count)
                expect(UniformPacket.local_light_byte_size(prefix_count))
                    :to_be((1 + count * 6) * 16)

                UniformPacket.send_local_lights(full_shader, full_scratch)
                UniformPacket.send_local_lights(
                    prefix_shader, prefix_scratch, prefix_count)
                draw_count_gated(full_shader, full_canvas)
                draw_count_gated(prefix_shader, prefix_canvas)
                local full_pixels = full_canvas:newImageData()
                local prefix_pixels = prefix_canvas:newImageData()
                local fr, fg, fb, fa = full_pixels:getPixel(0, 0)
                local pr, pg, pb, pa = prefix_pixels:getPixel(0, 0)
                expect(pr):to_be_near(fr, 1e-6)
                expect(pg):to_be_near(fg, 1e-6)
                expect(pb):to_be_near(fb, 1e-6)
                expect(pa):to_be_near(fa, 1e-6)
                release(full_pixels)
                release(prefix_pixels)
            end
            expect(UniformPacket.local_light_byte_size()):to_be(400)
            release(full_scratch.data)
            release(prefix_scratch.data)
            release(full_canvas)
            release(prefix_canvas)
            release(full_shader)
            release(prefix_shader)
        end)

        t.it("uses the one packet without constructing legacy send tables", function()
            local core, scratch, noted_sends =
                new_packet_core(RBX, UniformPacket)
            local shader = payload_shader()
            local first = immutable_pack(
                "packet-first", 1, { 0.1, 0.2, 0.3, 0 }, 0)
            local second = immutable_pack(
                "packet-second", 2, { 0.2, 0.3, 0.4, 0 }, 1)

            core:_send_local_light_uniforms(shader, first, true)
            core:_send_local_light_uniforms(shader, second, true)

            expect(core._frame_local_light_uniform_packet_send_count):to_be(2)
            expect(core._frame_local_light_uniform_legacy_send_count or 0):to_be(0)
            expect(core._frame_local_light_uniform_packet_failure_count or 0):to_be(0)
            expect(core._local_light_uniform_packet_allocation_count):to_be(1)
            expect(core._local_light_send_args):to_be_nil()
            expect(core._local_light_send_metadata):to_be_nil()
            expect(core._local_light_compact_send_vectors):to_be_nil()
            expect(core._local_light_uniform_packet_scratch.data)
                :to_be(scratch.data)
            expect(noted_sends()):to_be(2)

            release(scratch.data)
            release(shader)
        end)
    end)

    t.describe("local-light uniform packet fallbacks", function()
        t.it("downgrades one shader and commits cache only after legacy succeeds", function()
            local core, scratch, noted_sends =
                new_packet_core(RBX, UniformPacket)
            local shader = {}
            local legacy_attempts = 0
            shader.send = function()
                legacy_attempts = legacy_attempts + 1
                if legacy_attempts == 1 then
                    error("forced legacy failure")
                end
            end
            local pack = immutable_pack(
                "transactional-shader", 1, { 0.1, 0.2, 0.3, 0 }, 0)
            local original_is_real = UniformPacket.is_real_shader
            local original_send = UniformPacket.send_local_lights
            UniformPacket.is_real_shader = function(candidate)
                return candidate == shader
            end
            UniformPacket.send_local_lights = function()
                error("forced packet failure")
            end
            local first_ok = pcall(
                core._send_local_light_uniforms,
                core,
                shader,
                pack,
                true
            )
            UniformPacket.send_local_lights = original_send

            expect(first_ok):to_be(false)
            expect(core._local_light_uniform_state[shader]):to_be_nil()
            expect(core._local_light_uniform_packet_shader_support[shader])
                :to_be(false)
            expect(core._frame_local_light_uniform_packet_failure_count):to_be(1)
            expect(noted_sends()):to_be(0)

            local second_ok, second_error = pcall(
                core._send_local_light_uniforms,
                core,
                shader,
                pack,
                true
            )
            UniformPacket.is_real_shader = original_is_real
            t.assert_that(second_ok, tostring(second_error))
            expect(core._local_light_uniform_state[shader])
                :to_be(RBX._local_light_pack_payload_key(pack))
            expect(core._frame_local_light_uniform_legacy_send_count):to_be(1)
            expect(core._frame_local_light_uniform_packet_fallback_send_count)
                :to_be(1)
            expect(core._local_light_uniform_packet_shader_fallback_count)
                :to_be(1)
            expect(noted_sends()):to_be(1)
            release(scratch.data)
        end)

        t.it("makes a writer failure renderer-global without reallocating", function()
            local core, scratch = new_packet_core(RBX, UniformPacket)
            local shader = {
                send = function()
                end,
            }
            local first = immutable_pack(
                "global-first", 1, { 0.1, 0.2, 0.3, 0 }, 0)
            local second = immutable_pack(
                "global-second", 1, { 0.2, 0.3, 0.4, 0 }, 1)
            local original_is_real = UniformPacket.is_real_shader
            local original_write = UniformPacket.write_local_lights
            local writer_attempts = 0
            UniformPacket.is_real_shader = function(candidate)
                return candidate == shader
            end
            UniformPacket.write_local_lights = function()
                writer_attempts = writer_attempts + 1
                error("forced writer failure")
            end

            core:_send_local_light_uniforms(shader, first, true)
            UniformPacket.write_local_lights = original_write
            core:_send_local_light_uniforms(shader, second, true)
            UniformPacket.is_real_shader = original_is_real

            expect(writer_attempts):to_be(1)
            expect(core._local_light_uniform_packet_available):to_be(false)
            expect(core._local_light_uniform_packet_global_fallback_reason)
                :to_contain("forced writer failure")
            expect(core._local_light_uniform_packet_allocation_count):to_be(1)
            expect(core._frame_local_light_uniform_packet_failure_count):to_be(1)
            expect(core._frame_local_light_uniform_legacy_send_count):to_be(2)
            expect(core._frame_local_light_uniform_packet_fallback_send_count)
                :to_be(2)
            expect(core._local_light_uniform_state[shader])
                :to_be(RBX._local_light_pack_payload_key(second))
            release(scratch.data)
        end)
    end)

    t.describe("local-light uniform packet lifecycle", function()
        t.it("releases the renderer-owned ByteData once and destroys idempotently", function()
            local game, create_error = RBX.new({
                render_backend = "menori",
                enable_skybox = false,
                allow_remote_asset_fetch = false,
                allow_remote_mesh_fetch = false,
                physics_enabled = false,
                shader_quality = "fast",
                msaa = 0,
            })
            t.assert_that(game ~= nil, tostring(create_error))
            local core = game._core
            local scratch = core._local_light_uniform_packet_scratch
            t.assert_that(scratch and scratch.data,
                "renderer did not retain its uniform packet")
            local data = scratch.data
            expect(data:getSize()):to_be(400)
            expect(core._local_light_uniform_packet_allocation_count):to_be(1)
            if data.isReleased then
                expect(data:isReleased()):to_be(false)
            end

            game:Destroy()
            expect(core._destroyed):to_be(true)
            expect(core._local_light_uniform_packet_scratch):to_be_nil()
            if data.isReleased then
                expect(data:isReleased()):to_be(true)
            end
            expect(core:Destroy(game)):to_be(false)
        end)
    end)
end

return suite
