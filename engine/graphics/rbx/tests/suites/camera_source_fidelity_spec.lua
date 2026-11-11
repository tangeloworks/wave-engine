-- Camera byte decoding -> runtime source -> DataModel value types. These tests
-- deliberately promote cameras below a Folder and never prescribe which camera
-- an imported Workspace selects or how malformed direct-camera siblings behave.
local suite = {}

local MODULES = {
    "common.lua", "gui.lua", "parser.lua", "scene.lua", "datamodel.lua", "render.lua",
}
local CAMERA_TYPES = { "Fixed", "Attach", "Watch", "Track", "Follow", "Custom", "Scriptable", "Orbital" }
local POSE = { 11, -7, 23, .8, 0, .6, 0, 1, 0, -.6, 0, .8 }
local FOCUS = { -2, 5, -13, 1, 0, 0, 0, .8, -.6, 0, .6, .8 }
local ALIAS_POSE = { -31, 22, 49, 0, -1, 0, 1, 0, 0, 0, 0, 1 }
local ALIAS_FOCUS = { 18, -37, 62, 1, 0, 0, 0, 0, -1, 0, 1, 0 }
-- Studio 0.737 native-camera-source-20260908.txt: fresh Camera and an
-- authored Camera with omitted fields agree; neither inherits the live camera.
local DEFAULT_POSE = { 0, 20, 20, 1, 0, 0, 0, .7071068286895752, .7071068286895752,
    0, -.7071068286895752, .7071068286895752 }
local DEFAULT_FOCUS = { 0, 0, -5, 1, 0, 0, 0, 1, 0, 0, 0, 1 }
local CF_KEYS = { "X", "Y", "Z", "R00", "R01", "R02", "R10", "R11", "R12", "R20", "R21", "R22" }
local CACHE_NAME = "__rbx_camera_source_fidelity_spec"
local CACHE_PATH = "map_cache/" .. CACHE_NAME .. ".mapcache"

local function fixture_nodes(direct_cameras)
    local nodes = {}
    local function node(class, name, parent, properties)
        local value = { id = #nodes + 1, class = class, name = name,
            parent = parent and parent.id or -1, properties = properties or {} }
        table.insert(value.properties, 1, { "String", "Name", name })
        nodes[#nodes + 1] = value
        return value
    end
    local workspace = node("Workspace", "Workspace")
    local folder = node("Folder", "CameraFixture", workspace)
    local camera_parent = direct_cameras and workspace or folder
    -- A real serialized subject/reference is inventoried without conflating
    -- preservation of camera values with runtime Instance-reference resolution.
    local subject = node("Part", "AuthoredSubject", workspace, {
        { "Bool", "Anchored", true }, { "Vector3", "size", { 2, 2, 2 } },
        { "CFrame", "CFrame", POSE },
    })
    local first, tracked
    for index, name in ipairs(CAMERA_TYPES) do
        local camera = node("Camera", "Authored" .. name, camera_parent, {
            { "CFrame", "CFrame", POSE }, { "CFrame", "Focus", FOCUS },
            { "Float32", "FieldOfView", 53 }, { "Enum", "CameraType", index - 1 },
            { "Referent", "CameraSubject", subject.id },
        })
        first = first or camera
        if name == "Track" then tracked = camera end
    end
    workspace.properties[#workspace.properties + 1] = { "Referent", "CurrentCamera", first.id }
    node("Camera", "LegacyAliases", camera_parent, {
        { "CFrame", "CoordinateFrame", POSE }, { "CFrame", "focus", FOCUS },
        { "Float32", "FieldOfView", 47 }, { "Enum", "CameraType", 3 },
    })
    node("Camera", "CanonicalThenLegacy", camera_parent, {
        { "CFrame", "CFrame", POSE }, { "CFrame", "Focus", FOCUS },
        { "CFrame", "CoordinateFrame", ALIAS_POSE }, { "CFrame", "focus", ALIAS_FOCUS },
    })
    node("Camera", "LegacyThenCanonical", camera_parent, {
        { "CFrame", "CoordinateFrame", ALIAS_POSE }, { "CFrame", "focus", ALIAS_FOCUS },
        { "CFrame", "CFrame", POSE }, { "CFrame", "Focus", FOCUS },
    })
    node("Camera", "MissingFields", camera_parent)
    for _, malformed in ipairs({ { "Negative", "Enum", -1 },
        { "OutOfRange", "Enum", 99 }, { "Text", "MalformedEnumText", "bad" } }) do
        node("Camera", "Malformed" .. malformed[1], camera_parent, {
            { "CFrame", "CFrame", POSE }, { "CFrame", "Focus", FOCUS },
            { "Float32", "FieldOfView", 53 }, { malformed[2], "CameraType", malformed[3] },
        })
    end
    node("Folder", "AuthoredCameraChild", tracked)
    return nodes
end

local function xml_bytes(nodes)
    local tags = { String = "string", Bool = "bool", Float32 = "float", Enum = "token", MalformedEnumText = "token" }
    local function property_bytes(property)
        local kind, name, value = unpack(property)
        if kind == "Referent" then
            return string.format('<Ref name="%s">RBX%d</Ref>', name, value)
        elseif tags[kind] then
            return string.format('<%s name="%s">%s</%s>', tags[kind], name, tostring(value), tags[kind])
        end
        local out = {}
        local keys = kind == "CFrame" and CF_KEYS or { "X", "Y", "Z" }
        for index, key in ipairs(keys) do
            out[#out + 1] = string.format('<%s>%.17g</%s>', key, value[index], key)
        end
        local tag = kind == "CFrame" and "CoordinateFrame" or kind
        return string.format('<%s name="%s">%s</%s>', tag, name, table.concat(out), tag)
    end
    local output = { '<roblox version="4">' }
    local function append(parent)
        for _, node in ipairs(nodes) do
            if node.parent == parent then
                output[#output + 1] = string.format('<Item class="%s" referent="RBX%d"><Properties>', node.class, node.id)
                for _, property in ipairs(node.properties) do output[#output + 1] = property_bytes(property) end
                output[#output + 1] = '</Properties>'
                append(node.id)
                output[#output + 1] = '</Item>'
            end
        end
    end
    append(-1)
    output[#output + 1] = '</roblox>'
    return table.concat(output, '\n')
end

local function binary_bytes(nodes)
    local binary = require("engine/graphics/rbx/binary")
    local constants = require("engine/graphics/rbx/constants")
    local Writer = binary.Writer
    local function chunk(signature, payload)
        local writer = Writer.new()
        writer:put_bytes(signature)
        writer:put_u32le(0)
        writer:put_u32le(#payload)
        writer:put_u32le(0)
        writer:put_bytes(payload)
        return writer:to_string()
    end
    local header = Writer.new()
    header:put_bytes(constants.BINARY_SIGNATURE)
    header:put_u16le(0)
    header:put_u32le(#nodes)
    header:put_u32le(#nodes)
    header:put_bytes(string.rep('\0', 8))
    local output = { header:to_string() }
    -- One class ID per instance permits genuinely absent legacy/canonical
    -- properties, with no fabricated values on other Camera instances.
    for _, node in ipairs(nodes) do
        local inst = Writer.new()
        inst:put_u32le(node.id - 1)
        inst:put_string(node.class)
        inst:put_u8(0)
        inst:put_u32le(1)
        binary.write_referent_array(inst, { node.id })
        output[#output + 1] = chunk("INST", inst:to_string())
    end
    for _, node in ipairs(nodes) do
        for _, property in ipairs(node.properties) do
            local kind, name, value = unpack(property)
            local writer = Writer.new()
            writer:put_u32le(node.id - 1)
            writer:put_string(name)
            -- Text cannot inhabit binary's unsigned Enum slot. Its binary
            -- companion deliberately uses an incorrect String property type
            -- to exercise safe source normalization; the native oracle proves
            -- the XML malformed-token case, not this wrong-wire-type case.
            writer:put_u8(constants.DATA_TYPES[kind == "MalformedEnumText" and "String" or kind])
            if kind == "String" or kind == "MalformedEnumText" then writer:put_string(value)
            elseif kind == "Bool" then writer:put_u8(value and 1 or 0)
            elseif kind == "Enum" then binary.write_interleaved_u32_array(writer, { value })
            elseif kind == "Referent" then binary.write_referent_array(writer, { value })
            elseif kind == "Float32" then binary.write_interleaved_float_array(writer, { value })
            else
                if kind == "CFrame" then
                    writer:put_u8(0)
                    for component = 4, 12 do writer:put_f32le(value[component]) end
                end
                for axis = 1, 3 do binary.write_interleaved_float_array(writer, { value[axis] }) end
            end
            output[#output + 1] = chunk("PROP", writer:to_string())
        end
    end
    local children, parents = {}, {}
    for _, node in ipairs(nodes) do children[#children + 1], parents[#parents + 1] = node.id, node.parent end
    local prnt = Writer.new()
    prnt:put_u8(0)
    prnt:put_u32le(#nodes)
    binary.write_referent_array(prnt, children)
    binary.write_referent_array(prnt, parents)
    output[#output + 1] = chunk("PRNT", prnt:to_string())
    output[#output + 1] = chunk("END\0", binary.END_MAGIC)
    return table.concat(output)
end

local function index_sources(roots)
    local indexed = {}
    local function visit(node)
        indexed[node.Name] = node
        for _, child in ipairs(node.Children or {}) do visit(child) end
    end
    for _, root in ipairs(roots) do visit(root) end
    return indexed
end

local function parse_fixture(RBX, format, direct_cameras, transform_nodes)
    local nodes = fixture_nodes(direct_cameras)
    if transform_nodes then transform_nodes(nodes) end
    local bytes = format == "xml" and xml_bytes(nodes) or binary_bytes(nodes)
    local path = "camera-source-fidelity." .. (format == "xml" and "rbxlx" or "rbxl")
    local parsed, err = RBX._parse_map_data(path, bytes, { include_instance_roots = true })
    assert(parsed, tostring(err))
    assert(#parsed.instance_roots > 0, "camera fixture produced no source roots")
    return parsed, index_sources(parsed.instance_roots)
end

local function make_game(RBX)
    -- Real facade/core camera methods, with no GPU allocation or geometry build.
    local core = setmetatable({ parts = {}, constraints = {},
        _runtime_part_by_referent = {}, _runtime_part_by_id = {},
        _runtime_part_by_name = {}, _part_proxy_by_id = {},
        camera = { cframe = RBX.CFrame.new(90, 80, 70), focus = RBX.CFrame.new(60, 50, 40),
            fov = math.rad(70), camera_type = "Scriptable" },
    }, { __index = RBX })
    local game = core:_create_datamodel_public({})
    local folder = game._instance_api.new("Folder", { Name = "CameraFixture", Parent = game.Workspace })
    -- Keep bootstrap below the Folder as well: switching tests are not an
    -- assertion about native deletion of direct Workspace camera siblings.
    game.Workspace.CurrentCamera.Parent = folder
    return game, core, folder
end

local function promote(game, folder, source)
    local camera = game:_promote_source_node(source)
    camera.Parent = folder
    return camera
end

local function is_descendant_of(instance, ancestor)
    local current = instance and instance.Parent
    while current do
        if current == ancestor then return true end
        current = current.Parent
    end
    return false
end

local function count_referent(game, referent)
    local count = 0
    for _, instance in ipairs(game:GetDescendants()) do
        if rawget(instance, "_referent") == referent then count = count + 1 end
    end
    return count
end

local function promote_map_generation(game, core, path, parsed)
    -- Production promotes while _map_build_path names the INCOMING map and
    -- map_path can still name the previously committed map.
    core._map_build_path = path
    game:_promote_instance_roots(parsed.instance_roots)
    core.map_path = path
    core._map_build_path = nil
end

local function expect_frame(t, value, expected, label, cframe_type)
    t.assert_that(type(value) == "table", "%s is not a CFrame value", label)
    if cframe_type then
        t.expect(getmetatable(value)):to_be(cframe_type)
        t.expect(type(value.clone)):to_be("function")
    end
    for index, key in ipairs(CF_KEYS) do t.expect(value[key]):to_be_near(expected[index], 1e-6) end
end

local function expect_camera(t, RBX, camera, name, field_of_view)
    expect_frame(t, camera.CFrame, POSE, name .. ".CFrame", RBX.CFrame)
    expect_frame(t, camera.Focus, FOCUS, name .. ".Focus", RBX.CFrame)
    t.expect(camera.FieldOfView):to_be(field_of_view or 53)
    t.expect(camera.CameraType):to_be(RBX.Enum.CameraType[name])
    t.expect(camera.CameraType.Name):to_be(name)
end

local function with_cache(callback)
    local function remove() if love.filesystem.getInfo(CACHE_PATH) then love.filesystem.remove(CACHE_PATH) end end
    remove()
    local ok, err = xpcall(callback, debug.traceback)
    remove()
    if not ok then error(err, 0) end
end

function suite.run(t, harness)
    for _, module in ipairs(MODULES) do harness.runtime_require(module) end
    local RBX = harness.env.RBX
    t.describe("serialized Camera source fidelity", function()
        for _, format in ipairs({ "xml", "binary" }) do
            t.it(format .. " decodes authored camera scalars, matrices and reference bytes before conversion", function()
                local _, sources = parse_fixture(RBX, format)
                local camera, workspace = sources.AuthoredFixed._dom_instance, sources.Workspace._dom_instance
                for _, field in ipairs({ "CFrame", "Focus", "FieldOfView", "CameraType", "CameraSubject" }) do
                    t.assert_that(camera.properties[field] ~= nil, "raw DOM dropped Camera.%s", field)
                end
                t.expect(camera.properties.FieldOfView.value):to_be(53)
                t.expect(camera.properties.CameraType.value):to_be(0)
                t.expect(camera.properties.CameraSubject.value):to_be(sources.AuthoredSubject.Referent)
                t.expect(workspace.properties.CurrentCamera.value):to_be(sources.AuthoredFixed.Referent)
                expect_frame(t, harness.env.convert_dom_property_value(camera.properties.CFrame), POSE, "DOM CFrame")
                expect_frame(t, harness.env.convert_dom_property_value(camera.properties.Focus), FOCUS, "DOM Focus")
            end)

            t.it(format .. " retains authored Camera values at the production DOM-to-source boundary", function()
                local _, sources = parse_fixture(RBX, format)
                for index, name in ipairs(CAMERA_TYPES) do
                    local source = sources["Authored" .. name]
                    expect_frame(t, source.CFrame, POSE, "Source CFrame")
                    expect_frame(t, source.Focus, FOCUS, "Source Focus")
                    t.expect(source.FieldOfView):to_be(53)
                    -- Numeric enum storage is valid here; public enum identity
                    -- is asserted independently after source promotion.
                    t.expect(source.CameraType):to_be(index - 1)
                end
            end)

            t.it(format .. " promotes every CameraType as usable non-current CFrame and enum values", function()
                local _, sources = parse_fixture(RBX, format)
                local game, core, folder = make_game(RBX)
                local initial_pose = core.camera.cframe
                for _, name in ipairs(CAMERA_TYPES) do
                    local camera = promote(game, folder, sources["Authored" .. name])
                    expect_camera(t, RBX, camera, name)
                    t.expect(core.camera.cframe):to_be(initial_pose)
                end
            end)

            t.it(format .. " accepts legacy-only CoordinateFrame and lowercase focus fields", function()
                local _, sources = parse_fixture(RBX, format)
                local source = sources.LegacyAliases
                expect_frame(t, source.CFrame, POSE, "effective Source CFrame")
                expect_frame(t, source.Focus, FOCUS, "effective Source Focus")
                expect_frame(t, source.CoordinateFrame, POSE, "Source CoordinateFrame")
                expect_frame(t, source.focus, FOCUS, "Source focus")
                local game, _, folder = make_game(RBX)
                local camera = promote(game, folder, source)
                expect_camera(t, RBX, camera, "Track", 47)
                t.expect(camera.CoordinateFrame):to_be(camera.CFrame)
                t.expect(camera.focus):to_be(camera.Focus)
            end)

            t.it(format .. " applies conflicting camera aliases in authored order through promotion, clone and cache", function()
                -- Native V2 observes last-authored-property wins in BOTH XML
                -- orders. The binary companion exercises equivalent ordered
                -- PROP chunks through the common source-conversion boundary.
                with_cache(function()
                    local parsed, sources = parse_fixture(RBX, format)
                    local cache = require("engine/graphics/rbx/map_cache")
                    local saved, err = cache.save(CACHE_NAME, "camera-alias-order-" .. format, parsed)
                    t.assert_that(saved == true, "alias-order cache save failed: %s", tostring(err))
                    local warm = cache.load(CACHE_NAME, "camera-alias-order-" .. format)
                    t.assert_that(type(warm) == "table", "alias-order cache load failed")
                    local warm_sources = index_sources(warm.instance_roots)
                    local game, _, folder = make_game(RBX)
                    for _, order in ipairs({
                        { "CanonicalThenLegacy", ALIAS_POSE, ALIAS_FOCUS, true },
                        { "LegacyThenCanonical", POSE, FOCUS, false },
                    }) do
                        local name, pose, focus, legacy_last = unpack(order)
                        local original = sources[name]
                        local positions = {}
                        for index, property in ipairs(original._dom_instance.propertyOrder) do positions[property] = index end
                        t.expect(positions.CoordinateFrame > positions.CFrame):to_be(legacy_last)
                        t.expect(positions.focus > positions.Focus):to_be(legacy_last)
                        for _, source in ipairs({ original, warm_sources[name] }) do
                            expect_frame(t, source.CFrame, pose, name .. " effective Source CFrame")
                            expect_frame(t, source.Focus, focus, name .. " effective Source Focus")
                            local camera = promote(game, folder, source)
                            for _, instance in ipairs({ camera, camera:Clone() }) do
                                expect_frame(t, instance.CFrame, pose, name .. " facade CFrame", RBX.CFrame)
                                expect_frame(t, instance.Focus, focus, name .. " facade Focus", RBX.CFrame)
                                t.expect(instance.CoordinateFrame):to_be(instance.CFrame)
                                t.expect(instance.focus):to_be(instance.Focus)
                            end
                        end
                    end
                end)
            end)

            t.it(format .. " keeps canonical and legacy camera getter/setter aliases linked while inactive and active", function()
                local _, sources = parse_fixture(RBX, format)
                local source = sources.LegacyAliases
                local game, core, folder = make_game(RBX)
                local camera = promote(game, folder, source)
                local original_active = core.camera.cframe
                local pose, focus = RBX.CFrame.new(unpack(ALIAS_POSE)), RBX.CFrame.new(unpack(ALIAS_FOCUS))
                camera.CoordinateFrame, camera.focus = pose, focus
                expect_frame(t, camera.CFrame, ALIAS_POSE, "alias setter CFrame", RBX.CFrame)
                expect_frame(t, camera.Focus, ALIAS_FOCUS, "alias setter Focus", RBX.CFrame)
                t.expect(camera.CoordinateFrame):to_be(camera.CFrame)
                t.expect(camera.focus):to_be(camera.Focus)
                t.expect(core.camera.cframe):to_be(original_active)
                camera.CFrame, camera.Focus = RBX.CFrame.new(unpack(POSE)), RBX.CFrame.new(unpack(FOCUS))
                expect_frame(t, camera.CoordinateFrame, POSE, "canonical setter CoordinateFrame", RBX.CFrame)
                expect_frame(t, camera.focus, FOCUS, "canonical setter focus", RBX.CFrame)
                game.Workspace.CurrentCamera = camera
                camera.CoordinateFrame, camera.focus = pose, focus
                expect_frame(t, core.camera.cframe, ALIAS_POSE, "active alias setter CFrame", RBX.CFrame)
                expect_frame(t, core.camera.focus, ALIAS_FOCUS, "active alias setter Focus", RBX.CFrame)
                t.expect(camera.CoordinateFrame):to_be(core.camera.cframe)
                t.expect(camera.focus):to_be(core.camera.focus)
                expect_frame(t, source.CFrame, POSE, "unchanged effective Source CFrame")
                expect_frame(t, source.Focus, FOCUS, "unchanged effective Source Focus")
            end)

            t.it(format .. " uses native fresh and omitted Camera defaults independently of the live renderer", function()
                local _, sources = parse_fixture(RBX, format)
                local game, core, folder = make_game(RBX)
                core.camera.fov = math.rad(91)
                local omitted = promote(game, folder, sources.MissingFields)
                local fresh = game._instance_api.new("Camera")
                for _, camera in ipairs({ omitted, fresh }) do
                    expect_frame(t, camera.CFrame, DEFAULT_POSE, "default CFrame", RBX.CFrame)
                    expect_frame(t, camera.Focus, DEFAULT_FOCUS, "default Focus", RBX.CFrame)
                    t.expect(camera.FieldOfView):to_be(70)
                    t.expect(camera.CameraType):to_be(RBX.Enum.CameraType.Fixed)
                end
                core.camera.cframe = RBX.CFrame.new(-100, -200, -300)
                core.camera.focus = RBX.CFrame.new(-400, -500, -600)
                core.camera.fov, core.camera.camera_type = math.rad(101), "Orbital"
                for _, camera in ipairs({ omitted, fresh }) do
                    expect_frame(t, camera.CFrame, DEFAULT_POSE, "independent default CFrame", RBX.CFrame)
                    expect_frame(t, camera.Focus, DEFAULT_FOCUS, "independent default Focus", RBX.CFrame)
                    t.expect(camera.FieldOfView):to_be(70)
                    t.expect(camera.CameraType):to_be(RBX.Enum.CameraType.Fixed)
                end
            end)

            t.it(format .. " defaults malformed serialized CameraType values without rejecting the map", function()
                local _, sources = parse_fixture(RBX, format)
                local game, _, folder = make_game(RBX)
                for _, name in ipairs({ "Negative", "OutOfRange", "Text" }) do
                    local camera = promote(game, folder, sources["Malformed" .. name])
                    expect_camera(t, RBX, camera, "Fixed")
                    t.expect(camera.CameraType.Value):to_be(0)
                end
            end)

            t.it(format .. " preserves Camera value types through clone, mutation, reparenting and cache reload", function()
                with_cache(function()
                    local parsed, sources = parse_fixture(RBX, format)
                    local source = sources.AuthoredTrack
                    -- Graph metadata is deliberately added AFTER byte decode;
                    -- this is not a claim that XML or RBXL serialized a cycle.
                    local shared = { marker = 17 }
                    source.CameraMetadata = { first = shared, second = shared }
                    source.CameraMetadata.self = source.CameraMetadata
                    local game, _, folder = make_game(RBX)
                    local camera = promote(game, folder, source)
                    local clone = camera:Clone()
                    expect_camera(t, RBX, clone, "Track")
                    t.expect(clone.CameraMetadata.first):to_be(clone.CameraMetadata.second)
                    t.expect(clone.CameraMetadata.self):to_be(clone.CameraMetadata)
                    t.assert_that(clone.CameraMetadata ~= camera.CameraMetadata, "clone aliases facade metadata")
                    t.assert_that(camera.CameraMetadata ~= source.CameraMetadata, "facade aliases source metadata")
                    local alternate = game._instance_api.new("Folder", { Name = "Alternate", Parent = folder })
                    clone.Parent = alternate
                    camera.Parent = alternate
                    camera.CFrame = RBX.CFrame.new(101, 102, 103)
                    camera.Focus = RBX.CFrame.new(104, 105, 106)
                    camera.FieldOfView = 71
                    camera.CameraType = RBX.Enum.CameraType.Custom
                    camera.CameraMetadata.first.marker = 99
                    expect_camera(t, RBX, clone, "Track")
                    t.expect(source.CameraMetadata.first.marker):to_be(17)
                    t.expect(clone.CameraMetadata.first.marker):to_be(17)
                    expect_frame(t, source.CFrame, POSE, "unmodified Source CFrame")
                    expect_frame(t, source.Focus, FOCUS, "unmodified Source Focus")
                    local cache = require("engine/graphics/rbx/map_cache")
                    local saved, err = cache.save(CACHE_NAME, "camera-source-" .. format, parsed)
                    t.assert_that(saved == true, "Camera source cache save failed: %s", tostring(err))
                    local warm = cache.load(CACHE_NAME, "camera-source-" .. format)
                    t.assert_that(type(warm) == "table", "Camera source cache could not be read")
                    local warm_source = index_sources(warm.instance_roots).AuthoredTrack
                    t.expect(warm_source._dom_instance):to_be_nil()
                    t.assert_that(warm_source ~= source, "cache replay aliases original source")
                    local replay = promote(game, folder, warm_source)
                    expect_camera(t, RBX, replay, "Track")
                    t.expect(replay.CameraMetadata.first.marker):to_be(17)
                    t.expect(replay.CameraMetadata.self):to_be(replay.CameraMetadata)
                    replay.CameraMetadata.first.marker = 41
                    t.expect(warm_source.CameraMetadata.first.marker):to_be(17)
                end)
            end)

            t.it(format .. " activates authored and cloned Camera values through the real renderer core", function()
                local _, sources = parse_fixture(RBX, format)
                local game, core, folder = make_game(RBX)
                local bootstrap = game.Workspace.CurrentCamera
                local authored = promote(game, folder, sources.AuthoredTrack)
                local clone = authored:Clone()
                clone.Parent = folder
                for _, camera in ipairs({ authored, clone }) do
                    game.Workspace.CurrentCamera = camera
                    t.expect(core._current_camera_instance):to_be(camera)
                    expect_frame(t, core.camera.cframe, POSE, "active core CFrame", RBX.CFrame)
                    expect_frame(t, core.camera.focus, FOCUS, "active core Focus", RBX.CFrame)
                    t.expect(core:get_camera_field_of_view()):to_be_near(53, 1e-10)
                    t.expect(core.camera.camera_type):to_be("Track")
                    game.Workspace.CurrentCamera = bootstrap
                    t.expect(core._current_camera_instance):to_be(bootstrap)
                end
            end)

            -- Library map replacement intentionally retains an embedding
            -- application's active camera. This is NOT a claim about Studio's
            -- destructive Workspace.CurrentCamera assignment semantics.
            t.it(format .. " replaces inactive direct source Cameras without accumulating warm generations", function()
                local parsed = parse_fixture(RBX, format, true)
                local game = make_game(RBX)
                local expected_count
                local previous_inactive
                for generation = 1, 3 do
                    game:_promote_instance_roots(parsed.instance_roots)
                    local count = 0
                    for _, child in ipairs(game.Workspace:GetChildren()) do
                        if child.ClassName == "Camera" and child ~= game.Workspace.CurrentCamera then
                            count = count + 1
                        end
                    end
                    if expected_count then t.expect(count):to_be(expected_count)
                    else
                        t.expect(count):to_be(#CAMERA_TYPES + 7)
                        expected_count = count
                    end
                    if previous_inactive then
                        t.expect(is_descendant_of(previous_inactive, game.Workspace)):to_be(false)
                    end
                    previous_inactive = game.Workspace:FindFirstChild("AuthoredTrack")
                    t.assert_that(previous_inactive ~= nil, "warm generation dropped authored Camera")
                    expect_camera(t, RBX, previous_inactive, "Track")
                end
            end)

            t.it(format .. " keeps a nested embedding CurrentCamera reachable during map replacement", function()
                local parsed = parse_fixture(RBX, format)
                local game, core, old_folder = make_game(RBX)
                local bootstrap = game.Workspace.CurrentCamera
                local pose, focus = bootstrap.CFrame, bootstrap.Focus
                for generation = 1, 3 do
                    game:_promote_instance_roots(parsed.instance_roots)
                    t.expect(game.Workspace.CurrentCamera):to_be(bootstrap)
                    t.expect(is_descendant_of(bootstrap, game.Workspace)):to_be(true)
                    t.expect(is_descendant_of(old_folder, game.Workspace)):to_be(false)
                    t.expect(core.camera.cframe):to_be(pose)
                    t.expect(core.camera.focus):to_be(focus)
                    t.expect(bootstrap.FieldOfView):to_be_near(70, 1e-10)
                    t.expect(bootstrap.CameraType):to_be(RBX.Enum.CameraType.Scriptable)
                end
            end)

            t.it(format .. " reuses an active authored referent and pose instead of duplicating it on warm replacement", function()
                local parsed, sources = parse_fixture(RBX, format)
                local game, core = make_game(RBX)
                game:_promote_instance_roots(parsed.instance_roots)
                local referent = sources.AuthoredTrack.Referent
                local active = game._instance_by_referent[referent]
                t.assert_that(active ~= nil, "initial promotion dropped authored Camera referent")
                game.Workspace.CurrentCamera = active
                local pose, focus = RBX.CFrame.new(111, 222, 333), RBX.CFrame.new(444, 555, 666)
                active.CFrame, active.Focus, active.FieldOfView = pose, focus, 61
                active.CameraType = RBX.Enum.CameraType.Custom
                for generation = 1, 2 do
                    local previous_parent = active.Parent
                    game:_promote_instance_roots(parsed.instance_roots)
                    t.expect(game.Workspace.CurrentCamera):to_be(active)
                    t.expect(game._instance_by_referent[referent]):to_be(active)
                    t.expect(is_descendant_of(active, game.Workspace)):to_be(true)
                    t.expect(active.Parent):to_be(game.Workspace:FindFirstChild("CameraFixture"))
                    t.assert_that(active.Parent ~= previous_parent, "active Camera retained an obsolete source parent")
                    local same_referent = 0
                    for _, instance in ipairs(game:GetDescendants()) do
                        if rawget(instance, "_referent") == referent then same_referent = same_referent + 1 end
                    end
                    t.expect(same_referent):to_be(1)
                    t.expect(core.camera.cframe):to_be(pose)
                    t.expect(core.camera.focus):to_be(focus)
                    t.expect(core:get_camera_field_of_view()):to_be_near(61, 1e-10)
                    t.expect(core.camera.camera_type):to_be("Custom")
                    expect_frame(t, sources.AuthoredTrack.CFrame, POSE, "retained source CFrame")
                    expect_frame(t, sources.AuthoredTrack.Focus, FOCUS, "retained source Focus")
                    t.expect(sources.AuthoredTrack.FieldOfView):to_be(53)
                end
            end)

            t.it(format .. " reuses active same-map identity across independently decoded source generations", function()
                local first, sources = parse_fixture(RBX, format)
                local second = parse_fixture(RBX, format)
                local game, core = make_game(RBX)
                local path = "camera-map-A." .. (format == "xml" and "rbxlx" or "rbxl")
                promote_map_generation(game, core, path, first)
                local referent = sources.AuthoredTrack.Referent
                local active = game._instance_by_referent[referent]
                game.Workspace.CurrentCamera = active
                local pose = RBX.CFrame.new(unpack(ALIAS_POSE))
                active.CFrame = pose
                promote_map_generation(game, core, path, second)
                t.expect(game.Workspace.CurrentCamera):to_be(active)
                t.expect(game._instance_by_referent[referent]):to_be(active)
                t.expect(count_referent(game, referent)):to_be(1)
                t.expect(core.camera.cframe):to_be(pose)
                t.expect(is_descendant_of(active, game.Workspace)):to_be(true)
            end)

            t.it(format .. " retires old active map-local referents before another map claims them", function()
                for _, incoming_class in ipairs({ "Camera", "Folder" }) do
                    local first, sources = parse_fixture(RBX, format)
                    local second, incoming_sources = parse_fixture(RBX, format, false, function(nodes)
                        for _, node in ipairs(nodes) do
                            if node.name == "AuthoredTrack" then
                                node.class, node.name = incoming_class, "MapBTarget"
                                node.properties = { { "String", "Name", node.name } }
                                if incoming_class == "Camera" then
                                    node.properties[#node.properties + 1] = { "CFrame", "CFrame", ALIAS_POSE }
                                    node.properties[#node.properties + 1] = { "CFrame", "Focus", ALIAS_FOCUS }
                                    node.properties[#node.properties + 1] = { "Float32", "FieldOfView", 47 }
                                    node.properties[#node.properties + 1] = { "Enum", "CameraType", 7 }
                                end
                            end
                        end
                    end)
                    local game, core = make_game(RBX)
                    local suffix = format == "xml" and "rbxlx" or "rbxl"
                    local path_a, path_b = "camera-map-A." .. suffix, "camera-map-B." .. suffix
                    promote_map_generation(game, core, path_a, first)
                    local referent = sources.AuthoredTrack.Referent
                    t.expect(incoming_sources.MapBTarget.Referent):to_be(referent)
                    local active = game._instance_by_referent[referent]
                    game.Workspace.CurrentCamera = active
                    local pose, focus = RBX.CFrame.new(121, 232, 343), RBX.CFrame.new(454, 565, 676)
                    active.CFrame, active.Focus, active.FieldOfView = pose, focus, 63
                    active.CameraType = RBX.Enum.CameraType.Custom
                    core._map_build_path = path_b
                    t.expect(core.map_path):to_be(path_a)
                    game:_promote_instance_roots(second.instance_roots)
                    local target = game._instance_by_referent[referent]
                    t.assert_that(target ~= nil and target ~= active, "different map reused old active facade")
                    t.expect(target.Name):to_be("MapBTarget")
                    t.expect(target.ClassName):to_be(incoming_class)
                    t.expect(count_referent(game, referent)):to_be(1)
                    t.assert_that(not rawget(active, "_referent"), "active camera retained previous map's referent")
                    t.expect(game.Workspace.CurrentCamera):to_be(active)
                    t.expect(is_descendant_of(active, game.Workspace)):to_be(true)
                    t.expect(core.camera.cframe):to_be(pose)
                    t.expect(core.camera.focus):to_be(focus)
                    t.expect(core:get_camera_field_of_view()):to_be_near(63, 1e-10)
                    t.expect(core.camera.camera_type):to_be("Custom")
                    if incoming_class == "Camera" then
                        expect_frame(t, target.CFrame, ALIAS_POSE, "incoming map Camera CFrame", RBX.CFrame)
                        expect_frame(t, target.Focus, ALIAS_FOCUS, "incoming map Camera Focus", RBX.CFrame)
                        t.expect(target.FieldOfView):to_be(47)
                        t.expect(target.CameraType):to_be(RBX.Enum.CameraType.Orbital)
                    end
                end
            end)

            t.it(format .. " retires an active authored referent when the same map removes its source Camera", function()
                local first, sources = parse_fixture(RBX, format)
                local second = parse_fixture(RBX, format, false, function(nodes)
                    for index = #nodes, 1, -1 do
                        if nodes[index].name == "AuthoredTrack" or nodes[index].name == "AuthoredCameraChild" then
                            table.remove(nodes, index)
                        end
                    end
                end)
                local game, core = make_game(RBX)
                local path = "camera-map-A." .. (format == "xml" and "rbxlx" or "rbxl")
                promote_map_generation(game, core, path, first)
                local referent = sources.AuthoredTrack.Referent
                local active = game._instance_by_referent[referent]
                game.Workspace.CurrentCamera = active
                local pose = RBX.CFrame.new(unpack(ALIAS_POSE))
                active.CFrame = pose
                promote_map_generation(game, core, path, second)
                t.expect(game.Workspace.CurrentCamera):to_be(active)
                t.expect(core.camera.cframe):to_be(pose)
                t.expect(is_descendant_of(active, game.Workspace)):to_be(true)
                t.assert_that(not rawget(active, "_referent"), "removed Camera still advertises obsolete referent")
                t.expect(game._instance_by_referent[referent]):to_be_nil()
                t.expect(count_referent(game, referent)):to_be(0)
            end)

            t.it(format .. " snapshots live core state when cloning an active Camera with stale stored properties", function()
                local _, sources = parse_fixture(RBX, format)
                local game, core, folder = make_game(RBX)
                local active = promote(game, folder, sources.AuthoredTrack)
                game.Workspace.CurrentCamera = active
                core:_set_camera_core_cframe(RBX.CFrame.new(unpack(ALIAS_POSE)))
                core:_set_camera_core_focus(RBX.CFrame.new(unpack(ALIAS_FOCUS)))
                core:_set_camera_core_field_of_view(87)
                core:_set_camera_core_type("Orbital")
                expect_frame(t, rawget(active, "_properties").CFrame, POSE, "stale stored active CFrame", RBX.CFrame)
                local clone = active:Clone()
                expect_frame(t, clone.CFrame, ALIAS_POSE, "active clone CFrame", RBX.CFrame)
                expect_frame(t, clone.Focus, ALIAS_FOCUS, "active clone Focus", RBX.CFrame)
                t.expect(clone.FieldOfView):to_be_near(87, 1e-10)
                t.expect(clone.CameraType):to_be(RBX.Enum.CameraType.Orbital)
                t.expect(clone.Parent):to_be_nil()
                clone.CFrame, clone.Focus, clone.FieldOfView = RBX.CFrame.new(), RBX.CFrame.new(), 42
                clone.CameraType = RBX.Enum.CameraType.Fixed
                expect_frame(t, active.CFrame, ALIAS_POSE, "unmodified active CFrame", RBX.CFrame)
                expect_frame(t, active.Focus, ALIAS_FOCUS, "unmodified active Focus", RBX.CFrame)
                t.expect(active.FieldOfView):to_be_near(87, 1e-10)
                t.expect(active.CameraType):to_be(RBX.Enum.CameraType.Orbital)
            end)

            t.it(format .. " replaces reused Camera authored children while preserving its runtime-created children", function()
                local parsed, sources = parse_fixture(RBX, format)
                local game, core = make_game(RBX)
                local path = "camera-map-A." .. (format == "xml" and "rbxlx" or "rbxl")
                promote_map_generation(game, core, path, parsed)
                local active = game._instance_by_referent[sources.AuthoredTrack.Referent]
                game.Workspace.CurrentCamera = active
                local runtime_child = game._instance_api.new("Folder", { Name = "RuntimeCameraChild", Parent = active })
                for generation = 1, 2 do
                    local old_authored = active:FindFirstChild("AuthoredCameraChild")
                    t.assert_that(old_authored ~= nil, "authored Camera child missing before replacement")
                    promote_map_generation(game, core, path, parsed)
                    t.expect(game.Workspace.CurrentCamera):to_be(active)
                    t.expect(old_authored.Parent):to_be_nil()
                    t.expect(runtime_child.Parent):to_be(active)
                    local new_authored = active:FindFirstChild("AuthoredCameraChild")
                    t.assert_that(new_authored ~= nil and new_authored ~= old_authored, "obsolete authored Camera child reused")
                    t.expect(game._instance_by_referent[sources.AuthoredCameraChild.Referent]):to_be(new_authored)
                    t.expect(#active:GetChildren()):to_be(2)
                    t.expect(count_referent(game, sources.AuthoredCameraChild.Referent)):to_be(1)
                end
            end)
        end
    end)
end

return suite
