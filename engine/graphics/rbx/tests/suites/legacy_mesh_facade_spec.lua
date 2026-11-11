-- Public DataModelMesh lifecycle and its flattened render-core bridge.

local suite = {}
suite.needs_graphics = true

local RUNTIME_MODULES = {
    "common.lua",
    "gui.lua",
    "parser.lua",
    "scene.lua",
    "datamodel.lua",
}

local function contains(values, wanted)
    for index = 1, #values do
        if values[index] == wanted then return true end
    end
    return false
end

local function make_fixture(RBX)
    local core = setmetatable({
        parts = {},
        constraints = {},
        _loaded_part_count = 0,
        _runtime_part_storage_initialized = true,
        _runtime_live_part_count = 0,
        _next_part_id = 1,
        _part_proxy_by_id = {},
        _runtime_part_by_id = {},
        _runtime_part_by_name = {},
        _runtime_part_by_referent = {},
        _transform_dirty_parts = {},
        _appearance_promoted_parts = {},
        _appearance_promoted_count = 0,
        _debug_dirty_marks = { full = 0, transform = 0 },
    }, { __index = RBX })
    core._refresh_runtime_part_mass = function() end
    core._refresh_physics_part_registration = function() end
    core._invalidate_settled_merge_for_part = function() end
    core._remove_dynamic_scene_chunk_for_part = function() return true end
    core._gui_bridge_link_datamodel = function() end

    local production_mark = RBX._mark_runtime_part_legacy_mesh_dirty
    core._test_mesh_marks = {}
    core._mark_runtime_part_legacy_mesh_dirty = function(self, owner, source_changed)
        self._test_mesh_marks[#self._test_mesh_marks + 1] = {
            owner = owner,
            source_changed = source_changed == true,
        }
        return production_mark(self, owner, source_changed)
    end
    return core:_create_datamodel_public({}), core
end

local function reset_dirty(core)
    core._parts_dirty = false
    core._parts_dirty_mode = nil
    core._transform_dirty_parts = {}
    core._debug_dirty_marks = { full = 0, transform = 0 }
    core._test_mesh_marks = {}
end

local function new_part(game, name, properties)
    properties = properties or {}
    properties.Name = name
    properties.Parent = game.Workspace
    return game._instance_api.new("Part", properties)
end

local function xml_part(children)
    return [[
<roblox>
  <Item class="Part" referent="RBX_P">
    <Properties>
      <string name="Name">MeshCarrier</string>
      <CoordinateFrame name="CFrame"><X>0</X><Y>0</Y><Z>0</Z><R00>1</R00><R01>0</R01><R02>0</R02><R10>0</R10><R11>1</R11><R12>0</R12><R20>0</R20><R21>0</R21><R22>1</R22></CoordinateFrame>
      <Vector3 name="Size"><X>4</X><Y>2</Y><Z>6</Z></Vector3>
      <float name="Transparency">0</float>
    </Properties>]] .. children .. [[
  </Item>
</roblox>]]
end

local function mesh_xml(class_name, referent, scale_x, offset_x, extra)
    return string.format([[
    <Item class="%s" referent="%s">
      <Properties>
        <string name="Name">%s</string>
        <Vector3 name="Scale"><X>%s</X><Y>1</Y><Z>1</Z></Vector3>
        <Vector3 name="Offset"><X>%s</X><Y>0</Y><Z>0</Z></Vector3>
        %s
      </Properties>
    </Item>]], class_name, referent, referent, scale_x, offset_x, extra or "")
end

function suite.run(t, harness)
    for index = 1, #RUNTIME_MODULES do
        harness.runtime_require(RUNTIME_MODULES[index])
    end
    local RBX = harness.env.RBX
    local Vector3 = harness.env.Vector3
    local expect = t.expect

    t.describe("DataModelMesh public facade", function()
        t.it("exposes native hierarchy, defaults, value types, aliases, and support lists", function()
            local game, core = make_fixture(RBX)
            local special = game._instance_api.new("SpecialMesh")
            local block = game._instance_api.new("BlockMesh")
            local cylinder = game._instance_api.new("CylinderMesh")

            expect(special:IsA("SpecialMesh")):to_be(true)
            expect(special:IsA("FileMesh")):to_be(true)
            expect(special:IsA("DataModelMesh")):to_be(true)
            expect(special:IsA("Instance")):to_be(true)
            expect(block:IsA("BevelMesh")):to_be(true)
            expect(block:IsA("DataModelMesh")):to_be(true)
            expect(cylinder:IsA("BevelMesh")):to_be(true)
            expect(special.MeshType):to_be(RBX.Enum.MeshType.Head)
            expect(special.MeshId):to_be("")
            expect(special.MeshContent):to_be("")
            expect(special.TextureId):to_be("")
            expect(special.TextureContent):to_be("")
            expect(special.Scale):to_be(Vector3.one)
            expect(special.Offset):to_be(Vector3.zero)
            expect(special.VertexColor):to_be(Vector3.one)
            expect(block.Scale.X):to_be(1)
            expect(cylinder.Offset.Z):to_be(0)

            special.MeshContent = "  rbxassetid://101  "
            special.TextureID = "rbxassetid://202"
            expect(special.MeshId):to_be("rbxassetid://101")
            expect(special.MeshID):to_be("rbxassetid://101")
            expect(special.TextureContent):to_be("rbxassetid://202")
            special.MeshType = "Enum.MeshType.Cylinder"
            expect(special.MeshType):to_be(RBX.Enum.MeshType.Cylinder)

            expect(contains(game._instance_api.GetSupportedClasses(),
                "SpecialMesh")):to_be(true)
            expect(contains(core:_build_instance_api().GetSupportedClasses(),
                "BlockMesh")):to_be(true)
            expect(contains(RBX.Instance.GetSupportedClasses(),
                "CylinderMesh")):to_be(true)
            expect(special:GetPropertySchema().MeshId):to_be("ContentId")
            expect(block:GetPropertySchema().Scale):to_be("Vector3")

            expect(function() special.Scale = { X = 0 / 0, Y = 1, Z = 1 } end)
                :to_error("finite Vector3")
            expect(function() special.MeshType = "Triangle" end)
                :to_error("valid MeshType")
            expect(function() special.MeshType = 3.6 end)
                :to_error("valid MeshType")
            expect(function() block.MeshId = "rbxassetid://1" end)
                :to_error("not a valid property")
        end)

        t.it("activates an empty FileMesh and updates render bounds with one part-local mark", function()
            local game, core = make_fixture(RBX)
            local part = new_part(game, "Carrier", {
                Size = Vector3.new(4, 2, 6),
            })
            local handle = rawget(part, "_core_handle")
            local special = game._instance_api.new("SpecialMesh", {
                MeshType = RBX.Enum.MeshType.FileMesh,
                Scale = Vector3.new(0.5, 2, 3),
                Offset = Vector3.new(1, -2, 4),
                VertexColor = Vector3.new(0.25, 0.5, 0.75),
            })
            reset_dirty(core)
            special.Parent = part
            expect(#core._test_mesh_marks):to_be(1)
            expect(core._test_mesh_marks[1].owner):to_be(handle)
            expect(core._test_mesh_marks[1].source_changed):to_be(true)
            expect(handle.MeshOwner):to_be("SpecialMesh")
            expect(handle.SpecialMeshType):to_be("FileMesh")
            expect(handle.MeshId):to_be_nil()
            expect(handle.SpecialMeshScale.x):to_be(0.5)
            expect(handle.SpecialMeshVertexColor.g):to_be(0.5)

            reset_dirty(core)
            special.MeshId = "rbxassetid://303"
            expect(handle.MeshId):to_be("rbxassetid://303")
            expect(#core._test_mesh_marks):to_be(1)
            expect(core._test_mesh_marks[1].source_changed):to_be(true)
            expect(core._parts_dirty_mode):to_be("transform")

            reset_dirty(core)
            special.MeshID = "rbxassetid://303"
            expect(#core._test_mesh_marks):to_be(0)
            special.Scale = Vector3.new(2, 3, 4)
            expect(#core._test_mesh_marks):to_be(1)
            expect(core._test_mesh_marks[1].source_changed):to_be(false)
            expect(handle.SpecialMeshScale.z):to_be(4)
        end)

        t.it("uses the last authored DataModelMesh child across concrete classes", function()
            local game, core = make_fixture(RBX)
            local part = new_part(game, "Priority")
            local handle = rawget(part, "_core_handle")
            local folder = game._instance_api.new("Folder", { Parent = part })
            local first_block = game._instance_api.new("BlockMesh", {
                Scale = Vector3.new(2, 1, 1), Parent = part,
            })
            expect(handle.MeshOwner):to_be("BlockMesh")
            expect(handle.BlockMeshScale.x):to_be(2)

            local cylinder = game._instance_api.new("CylinderMesh", {
                Scale = Vector3.new(3, 1, 1), Parent = part,
            })
            expect(handle.MeshOwner):to_be("CylinderMesh")
            expect(handle.SpecialMeshScale.x):to_be(3)
            expect(handle.BlockMeshScale):to_be_nil()

            local first_special = game._instance_api.new("SpecialMesh", {
                Name = "FirstSpecial",
                MeshType = RBX.Enum.MeshType.Sphere,
                Scale = Vector3.new(4, 1, 1),
                Parent = part,
            })
            local second_special = game._instance_api.new("SpecialMesh", {
                Name = "SecondSpecial",
                MeshType = RBX.Enum.MeshType.Wedge,
                Scale = Vector3.new(9, 1, 1),
                Parent = part,
            })
            expect(handle.MeshOwner):to_be("SpecialMesh")
            expect(handle.SpecialMeshType):to_be("Wedge")
            expect(handle.SpecialMeshScale.x):to_be(9)

            reset_dirty(core)
            second_special.Scale = Vector3.new(12, 1, 1)
            expect(handle.SpecialMeshScale.x):to_be(12)
            expect(#core._test_mesh_marks):to_be(1)
            reset_dirty(core)
            first_special.Parent = folder
            expect(handle.SpecialMeshType):to_be("Wedge")
            expect(handle.SpecialMeshScale.x):to_be(12)
            expect(#core._test_mesh_marks):to_be(0)

            reset_dirty(core)
            second_special:Destroy()
            expect(handle.MeshOwner):to_be("CylinderMesh")
            expect(handle.SpecialMeshScale.x):to_be(3)
            expect(#core._test_mesh_marks):to_be(1)
            cylinder:Destroy()
            expect(handle.MeshOwner):to_be("BlockMesh")
            expect(handle.SpecialMeshScale):to_be_nil()
            first_block:Destroy()
            expect(handle.MeshOwner):to_be_nil()
            expect(handle.BlockMeshScale):to_be_nil()
        end)

        t.it("reparents one effective child across owners without duplicate state", function()
            local game, core = make_fixture(RBX)
            local first = new_part(game, "First")
            local second = new_part(game, "Second")
            local first_handle = rawget(first, "_core_handle")
            local second_handle = rawget(second, "_core_handle")
            local mesh = game._instance_api.new("CylinderMesh", {
                Scale = Vector3.new(2, 3, 4),
                Offset = Vector3.new(5, 6, 7),
                Parent = first,
            })
            reset_dirty(core)
            mesh.Parent = second
            expect(first_handle.MeshOwner):to_be_nil()
            expect(second_handle.MeshOwner):to_be("CylinderMesh")
            expect(second_handle.SpecialMeshScale.y):to_be(3)
            expect(#core._test_mesh_marks):to_be(2)
            expect(core._test_mesh_marks[1].owner):to_be(first_handle)
            expect(core._test_mesh_marks[2].owner):to_be(second_handle)
            expect(#first:GetChildren()):to_be(0)
            expect(#second:GetChildren()):to_be(1)
            expect(second:GetChildren()[1]):to_be(mesh)
        end)

        t.it("promotes loaded mesh children onto matching flattened fields without a rebuild", function()
            local game, core = make_fixture(RBX)
            local part = new_part(game, "Loaded")
            local handle = rawget(part, "_core_handle")
            handle._map_referent = "RBX_PART"
            core._runtime_part_by_referent.RBX_PART = handle
            handle.MeshOwner = "SpecialMesh"
            handle.MeshId = "rbxassetid://404"
            handle.TextureId = "rbxassetid://505"
            handle.TextureContent = "rbxassetid://505"
            handle.SpecialMeshType = "FileMesh"
            handle.SpecialMeshScale = { x = 2, y = 3, z = 4 }
            handle.SpecialMeshOffset = { x = 5, y = 6, z = 7 }
            handle.SpecialMeshVertexColor = { r = 0.2, g = 0.4, b = 0.6 }
            handle.BlockMeshScale = { x = 0.5, y = 1, z = 1 }
            handle.BlockMeshOffset = { x = 1, y = 0, z = 0 }
            reset_dirty(core)

            game:_promote_instance_roots({ {
                ClassName = "Workspace", Name = "Workspace", Children = { {
                    ClassName = "Part", Name = "Loaded", Referent = "RBX_PART",
                    Children = {
                        {
                            ClassName = "BlockMesh", Name = "LoadedBlock",
                            Referent = "RBX_BLOCK",
                            Scale = { X = 0.5, Y = 1, Z = 1 },
                            Offset = { X = 1, Y = 0, Z = 0 },
                            VertexColor = { X = 1, Y = 1, Z = 1 },
                            Children = {},
                        },
                        {
                            ClassName = "SpecialMesh", Name = "LoadedSpecial",
                            Referent = "RBX_SPECIAL", MeshType = 5,
                            MeshContent = "rbxassetid://404",
                            TextureContent = "rbxassetid://505",
                            Scale = { X = 2, Y = 3, Z = 4 },
                            Offset = { X = 5, Y = 6, Z = 7 },
                            VertexColor = { X = 0.2, Y = 0.4, Z = 0.6 },
                            Children = {},
                        },
                    },
                } },
            } })

            local loaded = game.Workspace:FindFirstChild("Loaded")
            local special = loaded:FindFirstChild("LoadedSpecial")
            local block = loaded:FindFirstChild("LoadedBlock")
            expect(#core._test_mesh_marks):to_be(0)
            expect(rawget(special, "_legacy_mesh_owner")):to_be(handle)
            expect(rawget(block, "_legacy_mesh_owner")):to_be(handle)
            expect(special.MeshId):to_be("rbxassetid://404")
            expect(special.TextureId):to_be("rbxassetid://505")
            expect(special.MeshType):to_be(RBX.Enum.MeshType.FileMesh)

            special.Offset = Vector3.new(8, 9, 10)
            expect(handle.SpecialMeshOffset.z):to_be(10)
            expect(#core._test_mesh_marks):to_be(1)
        end)

        t.it("clones public trees and legacy flat parts by value", function()
            local game, core = make_fixture(RBX)
            local part = new_part(game, "CloneSource")
            local handle = rawget(part, "_core_handle")
            local mesh = game._instance_api.new("SpecialMesh", {
                Name = "Mesh",
                MeshType = RBX.Enum.MeshType.FileMesh,
                MeshId = "rbxassetid://606",
                TextureId = "rbxassetid://707",
                Scale = Vector3.new(2, 3, 4),
                Offset = Vector3.new(5, 6, 7),
                VertexColor = Vector3.new(0.25, 0.5, 0.75),
                Parent = part,
            })
            local clone = part:Clone()
            local clone_handle = rawget(clone, "_core_handle")
            local clone_mesh = clone:FindFirstChild("Mesh")
            expect(clone_handle.MeshOwner):to_be("SpecialMesh")
            expect(clone_handle.MeshId):to_be("rbxassetid://606")
            expect(clone_mesh.Scale.X):to_be(2)
            t.assert_that(clone_handle.SpecialMeshScale
                    ~= handle.SpecialMeshScale,
                "public clone aliased the core mesh scale")
            mesh.Scale = Vector3.new(9, 9, 9)
            expect(clone_mesh.Scale.X):to_be(2)
            expect(clone_handle.SpecialMeshScale.x):to_be(2)

            local legacy_proxy = setmetatable({
                _renderer = core, _part = handle,
            }, harness.env.part_proxy_mt)
            local legacy_clone = legacy_proxy:Clone()
            local legacy_handle = rawget(legacy_clone, "_core_handle")
            expect(legacy_handle.MeshOwner):to_be("SpecialMesh")
            expect(legacy_handle.SpecialMeshType):to_be("FileMesh")
            expect(legacy_handle.SpecialMeshOffset.y):to_be(6)
            t.assert_that(legacy_handle.SpecialMeshOffset
                    ~= handle.SpecialMeshOffset,
                "legacy clone aliased the mesh offset")
        end)

        t.it("keeps regex fallback last-authored precedence in byte order", function()
            local children = table.concat({
                mesh_xml("BlockMesh", "FirstBlock", 2, 3,
                    [[<Vector3 name="VertexColor"><X>0.2</X><Y>0.4</Y><Z>0.6</Z></Vector3>]]),
                mesh_xml("BlockMesh", "SecondBlock", 9, 9),
                mesh_xml("CylinderMesh", "FirstCylinder", 4, 5),
                mesh_xml("CylinderMesh", "SecondCylinder", 8, 8),
                mesh_xml("SpecialMesh", "FirstSpecial", 6, 7,
                    [[<token name="MeshType">3</token>]]),
                mesh_xml("SpecialMesh", "SecondSpecial", 10, 10,
                    [[<token name="MeshType">2</token>]]),
            })
            local parts = harness.env.parse_supported_parts(
                xml_part(children), {})
            expect(#parts):to_be(1)
            expect(parts[1].mesh_owner):to_be("SpecialMesh")
            expect(parts[1].special_mesh_type):to_be("Wedge")
            expect(parts[1].special_mesh_scale.x):to_be(10)
            expect(parts[1].special_mesh_offset.x):to_be(10)
            expect(parts[1].blockmesh_scale):to_be_nil()
            expect(parts[1].blockmesh_offset):to_be_nil()

            local block_only = harness.env.parse_supported_parts(xml_part(
                mesh_xml("BlockMesh", "TintedBlock", 2, 3,
                    [[<Vector3 name="VertexColor"><X>0.2</X><Y>0.4</Y><Z>0.6</Z></Vector3>]])), {})
            expect(block_only[1].mesh_owner):to_be("BlockMesh")
            expect(block_only[1].mesh_vertex_color.r):to_be(0.2)
            expect(block_only[1].mesh_vertex_color.b):to_be(0.6)
        end)
    end)
end

return suite
