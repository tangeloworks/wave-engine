-- Public SurfaceAppearance lifecycle and its direct-MeshPart descriptor bridge.

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

    local production_mark = RBX._mark_runtime_part_surface_appearance_dirty
    core._test_surface_marks = {}
    core._mark_runtime_part_surface_appearance_dirty = function(self, owner)
        self._test_surface_marks[#self._test_surface_marks + 1] = owner
        return production_mark(self, owner)
    end
    return core:_create_datamodel_public({}), core
end

local function reset_dirty(core)
    core._parts_dirty = false
    core._parts_dirty_mode = nil
    core._transform_dirty_parts = {}
    core._debug_dirty_marks = { full = 0, transform = 0 }
    core._test_surface_marks = {}
end

local function new_part(game, class_name, name)
    return game._instance_api.new(class_name, {
        Name = name,
        MeshId = class_name == "MeshPart" and "rbxassetid://900" or nil,
        Parent = game.Workspace,
    })
end

function suite.run(t, harness)
    for index = 1, #RUNTIME_MODULES do
        harness.runtime_require(RUNTIME_MODULES[index])
    end
    local RBX = harness.env.RBX
    local Color3 = harness.env.Color3
    local SurfaceSemantics = harness.runtime_require("surface_appearance.lua")
    local expect = t.expect

    t.describe("SurfaceAppearance DataModel facade", function()
        t.it("exposes native hierarchy, defaults, enums, schema, and support lists", function()
            local game, core = make_fixture(RBX)
            local surface = game._instance_api.new("SurfaceAppearance")

            expect(surface.ClassName):to_be("SurfaceAppearance")
            expect(surface:IsA("SurfaceAppearance")):to_be(true)
            expect(surface:IsA("Instance")):to_be(true)
            expect(surface.AlphaMode):to_be(RBX.Enum.AlphaMode.Overlay)
            expect(surface.ResampleMode):to_be(RBX.Enum.ResamplerMode.Default)
            expect(surface.Color):to_be(Color3.new(1, 1, 1))
            expect(surface.EmissiveTint):to_be(Color3.new(1, 1, 1))
            expect(surface.EmissiveStrength):to_be(1)
            expect(surface.ColorMap):to_be("")
            expect(surface.ColorMapContent):to_be("")
            expect(surface.NormalMap):to_be("")
            expect(surface.NormalMapContent):to_be("")
            expect(surface.RoughnessMap):to_be("")
            expect(surface.RoughnessMapContent):to_be("")
            expect(surface.MetalnessMap):to_be("")
            expect(surface.MetalnessMapContent):to_be("")
            expect(surface.EmissiveMaskContent):to_be("")
            -- ColorSpace is deliberately role-derived, not a Roblox instance
            -- property or a renderer-facing public tuning knob.
            expect(surface.ColorSpace):to_be_nil()

            local schema = surface:GetPropertySchema()
            expect(schema.AlphaMode):to_be("AlphaMode")
            expect(schema.ColorMapContent):to_be("Content")
            expect(schema.ResampleMode):to_be("ResamplerMode")
            expect(contains(game._instance_api.GetSupportedClasses(),
                "SurfaceAppearance")):to_be(true)
            expect(contains(core:_build_instance_api().GetSupportedClasses(),
                "SurfaceAppearance")):to_be(true)
            expect(contains(RBX.Instance.GetSupportedClasses(),
                "SurfaceAppearance")):to_be(true)
        end)

        t.it("activates an empty child and dirties every effective renderer field exactly", function()
            local game, core = make_fixture(RBX)
            local mesh = new_part(game, "MeshPart", "Carrier")
            local handle = rawget(mesh, "_core_handle")
            local surface = game._instance_api.new("SurfaceAppearance")
            local bounds_cache = { sentinel = "bounds" }
            local mesh_cache = { sentinel = "mesh" }
            handle._rb_cache = bounds_cache
            handle._mesh_xf_cache = mesh_cache
            handle._surface_appearance_stats_generation = 17
            reset_dirty(core)

            surface.Parent = mesh
            expect(handle.SurfaceAppearance):to_be(
                rawget(surface, "_surface_appearance_descriptor"))
            expect(rawget(surface, "_surface_appearance_owner")):to_be(handle)
            expect(#core._test_surface_marks):to_be(1)
            expect(core._test_surface_marks[1]):to_be(handle)
            expect(handle._surface_appearance_stats_generation):to_be_nil()
            expect(handle._rb_cache):to_be(bounds_cache)
            expect(handle._mesh_xf_cache):to_be(mesh_cache)

            reset_dirty(core)
            local descriptor = handle.SurfaceAppearance
            surface.ColorMap = "  rbxassetid://1  "
            expect(descriptor.legacy_color_map):to_be("rbxassetid://1")
            expect(descriptor.color_map):to_be("rbxassetid://1")
            expect(#core._test_surface_marks):to_be(1)
            surface.ColorMapContent = "rbxassetid://2"
            expect(descriptor.color_map_content):to_be("rbxassetid://2")
            expect(descriptor.color_map):to_be("rbxassetid://2")
            expect(#core._test_surface_marks):to_be(2)
            -- A shadowed legacy source property still changes publicly, but the
            -- effective descriptor and GPU resources do not rebuild.
            surface.ColorMap = "rbxassetid://3"
            expect(surface.ColorMap):to_be("rbxassetid://3")
            expect(descriptor.color_map):to_be("rbxassetid://2")
            expect(#core._test_surface_marks):to_be(2)
            surface.ColorMapContent = ""
            expect(descriptor.color_map):to_be("rbxassetid://3")
            expect(#core._test_surface_marks):to_be(3)

            surface.NormalMap = "rbxassetid://10"
            surface.NormalMapContent = "rbxassetid://11"
            surface.RoughnessMap = "rbxassetid://20"
            surface.RoughnessMapContent = "rbxassetid://21"
            surface.MetalnessMap = "rbxassetid://30"
            surface.MetalnessMapContent = "rbxassetid://31"
            expect(descriptor.normal_map):to_be("rbxassetid://11")
            expect(descriptor.roughness_map):to_be("rbxassetid://21")
            expect(descriptor.metalness_map):to_be("rbxassetid://31")
            expect(#core._test_surface_marks):to_be(9)

            surface.AlphaMode = RBX.Enum.AlphaMode.TintMask
            surface.ResampleMode = "Enum.ResamplerMode.Pixelated"
            surface.Color = Color3.new(0.2, 0.4, 0.6)
            surface.EmissiveMaskContent = "rbxassetid://40"
            surface.EmissiveStrength = 7.5
            surface.EmissiveTint = Color3.new(0.9, 0.7, 0.5)
            expect(surface.AlphaMode):to_be(RBX.Enum.AlphaMode.TintMask)
            expect(surface.ResampleMode):to_be(
                RBX.Enum.ResamplerMode.Pixelated)
            expect(descriptor.alpha_mode):to_be(2)
            expect(descriptor.resample_mode):to_be(1)
            expect(descriptor.color[2]):to_be(0.4)
            expect(descriptor.emissive_mask):to_be("rbxassetid://40")
            expect(descriptor.emissive_strength):to_be(7.5)
            expect(descriptor.emissive_tint[3]):to_be(0.5)
            expect(#core._test_surface_marks):to_be(15)

            -- Compatibility-only TexturePack transport stays live without
            -- replacing the authoritative individual maps.
            surface.TexturePack = "rbxassetid://50"
            surface.TexturePackContent = "rbxassetid://51"
            surface.TexturePackMetadata = "orm"
            expect(descriptor.texture_pack):to_be("rbxassetid://51")
            expect(descriptor.texture_pack_metadata):to_be("orm")
            expect(#core._test_surface_marks):to_be(18)

            local normalized = SurfaceSemantics.normalize_descriptor(descriptor)
            expect(SurfaceSemantics.sampler_options(
                "color", normalized).color_space):to_be("srgb_color")
            expect(SurfaceSemantics.sampler_options(
                "normal", normalized).color_space):to_be("linear_data")
            expect(SurfaceSemantics.sampler_options(
                "roughness", normalized).color_space):to_be("linear_data")
            expect(SurfaceSemantics.sampler_options(
                "metalness", normalized).color_space):to_be("linear_data")
            expect(SurfaceSemantics.sampler_options(
                "emissive", normalized).color_space):to_be("linear_data")
            expect(core._parts_dirty_mode):to_be("transform")
            expect(handle._rb_cache):to_be(bounds_cache)
            expect(handle._mesh_xf_cache):to_be(mesh_cache)

            reset_dirty(core)
            surface.EmissiveStrength = 7.5
            surface.NormalMapContent = "rbxassetid://11"
            expect(#core._test_surface_marks):to_be(0)
            expect(function() surface.AlphaMode = "Blend" end)
                :to_error("valid AlphaMode")
            expect(function() surface.ResampleMode = 9 end)
                :to_error("valid ResampleMode")
            expect(function() surface.EmissiveStrength = 0 / 0 end)
                :to_error("finite number")
            expect(function() surface.Color = { math.huge, 0, 0 } end)
                :to_error("finite Color3")
        end)

        t.it("uses first-authored duplicate precedence and fails closed outside MeshPart", function()
            local game, core = make_fixture(RBX)
            local first_mesh = new_part(game, "MeshPart", "First")
            local second_mesh = new_part(game, "MeshPart", "Second")
            local part = new_part(game, "Part", "UnsupportedPart")
            local union = new_part(game, "UnionOperation", "UnsupportedUnion")
            local first_handle = rawget(first_mesh, "_core_handle")
            local second_handle = rawget(second_mesh, "_core_handle")
            local folder = game._instance_api.new("Folder", {
                Parent = first_mesh,
            })
            local first = game._instance_api.new("SurfaceAppearance", {
                Name = "FirstSurface",
                ColorMap = "rbxassetid://100",
                Parent = first_mesh,
            })
            local second = game._instance_api.new("SurfaceAppearance", {
                Name = "SecondSurface",
                ColorMap = "rbxassetid://200",
                Parent = first_mesh,
            })
            expect(first_handle.SurfaceAppearance.color_map)
                :to_be("rbxassetid://100")
            expect(rawget(first, "_surface_appearance_owner"))
                :to_be(first_handle)
            expect(rawget(second, "_surface_appearance_owner")):to_be(false)

            reset_dirty(core)
            second.ColorMap = "rbxassetid://201"
            expect(first_handle.SurfaceAppearance.color_map)
                :to_be("rbxassetid://100")
            expect(#core._test_surface_marks):to_be(0)
            first.Parent = folder
            expect(first_handle.SurfaceAppearance.color_map)
                :to_be("rbxassetid://201")
            expect(rawget(second, "_surface_appearance_owner"))
                :to_be(first_handle)
            expect(#core._test_surface_marks):to_be(1)

            reset_dirty(core)
            second.Parent = second_mesh
            expect(first_handle.SurfaceAppearance):to_be_nil()
            expect(second_handle.SurfaceAppearance.color_map)
                :to_be("rbxassetid://201")
            expect(#core._test_surface_marks):to_be(2)
            second:Destroy()
            expect(second_handle.SurfaceAppearance):to_be_nil()
            expect(#core._test_surface_marks):to_be(3)

            local inert_part = game._instance_api.new("SurfaceAppearance", {
                ColorMap = "rbxassetid://300",
                Parent = part,
            })
            local inert_union = game._instance_api.new("SurfaceAppearance", {
                ColorMap = "rbxassetid://301",
                Parent = union,
            })
            expect(rawget(part, "_core_handle").SurfaceAppearance):to_be_nil()
            expect(rawget(union, "_core_handle").SurfaceAppearance):to_be_nil()
            expect(rawget(inert_part, "_surface_appearance_owner")):to_be(false)
            expect(rawget(inert_union, "_surface_appearance_owner")):to_be(false)
            reset_dirty(core)
            inert_part.ColorMap = "rbxassetid://302"
            inert_union.ColorMap = "rbxassetid://303"
            expect(#core._test_surface_marks):to_be(0)
        end)

        t.it("promotes the loaded first child onto the parser descriptor without duplicate work", function()
            local game, core = make_fixture(RBX)
            local mesh = new_part(game, "MeshPart", "LoadedMesh")
            local handle = rawget(mesh, "_core_handle")
            handle._map_referent = "RBX_MESH"
            core._runtime_part_by_referent.RBX_MESH = handle
            local loaded = RBX._build_surface_appearance_descriptor({
                ClassName = "SurfaceAppearance",
                Name = "LoadedSurface",
                Referent = "RBX_SURFACE",
                ColorMap = "rbxassetid://401",
                NormalMapContent = "rbxassetid://402",
                RoughnessMap = "rbxassetid://403",
                MetalnessMapContent = "rbxassetid://404",
                AlphaMode = 1,
                Color = { R = 0.2, G = 0.4, B = 0.6 },
                EmissiveMaskContent = "rbxassetid://405",
                EmissiveStrength = 3,
                EmissiveTint = { R = 0.8, G = 0.7, B = 0.6 },
                ResampleMode = 1,
            }, 1)
            handle.SurfaceAppearance = loaded
            reset_dirty(core)

            game:_promote_instance_roots({ {
                ClassName = "Workspace", Name = "Workspace", Children = { {
                    ClassName = "MeshPart", Name = "LoadedMesh",
                    Referent = "RBX_MESH", Children = {
                        {
                            ClassName = "SurfaceAppearance",
                            Name = "LoadedSurface",
                            Referent = "RBX_SURFACE",
                            ColorMap = "rbxassetid://401",
                            NormalMapContent = "rbxassetid://402",
                            RoughnessMap = "rbxassetid://403",
                            MetalnessMapContent = "rbxassetid://404",
                            AlphaMode = 1,
                            Color = { R = 0.2, G = 0.4, B = 0.6 },
                            EmissiveMaskContent = "rbxassetid://405",
                            EmissiveStrength = 3,
                            EmissiveTint = { R = 0.8, G = 0.7, B = 0.6 },
                            ResampleMode = 1,
                            Children = {},
                        },
                        {
                            ClassName = "SurfaceAppearance",
                            Name = "DormantDuplicate",
                            Referent = "RBX_SURFACE_2",
                            ColorMap = "rbxassetid://999",
                            Children = {},
                        },
                    },
                } },
            } })

            local promoted_mesh = game.Workspace:FindFirstChild("LoadedMesh")
            local promoted = promoted_mesh:FindFirstChild("LoadedSurface")
            local duplicate = promoted_mesh:FindFirstChild("DormantDuplicate")
            expect(handle.SurfaceAppearance):to_be(loaded)
            expect(rawget(promoted, "_surface_appearance_descriptor"))
                :to_be(loaded)
            expect(rawget(promoted, "_surface_appearance_owner"))
                :to_be(handle)
            expect(rawget(duplicate, "_surface_appearance_owner")):to_be(false)
            expect(#core._test_surface_marks):to_be(0)
            expect(promoted.AlphaMode):to_be(
                RBX.Enum.AlphaMode.Transparency)
            expect(promoted.ResampleMode):to_be(
                RBX.Enum.ResamplerMode.Pixelated)
            expect(promoted.EmissiveTint.G):to_be(0.7)

            promoted.RoughnessMap = "rbxassetid://406"
            expect(loaded.roughness_map):to_be("rbxassetid://406")
            expect(#core._test_surface_marks):to_be(1)
        end)

        t.it("clones facades and MeshPart trees with independent owned values", function()
            local game = make_fixture(RBX)
            local mesh = new_part(game, "MeshPart", "CloneSource")
            local handle = rawget(mesh, "_core_handle")
            local surface = game._instance_api.new("SurfaceAppearance", {
                Name = "Surface",
                AlphaMode = RBX.Enum.AlphaMode.Opaque,
                Color = Color3.new(0.1, 0.2, 0.3),
                ColorMap = "rbxassetid://501",
                NormalMapContent = "rbxassetid://502",
                RoughnessMap = "rbxassetid://503",
                MetalnessMapContent = "rbxassetid://504",
                EmissiveMaskContent = "rbxassetid://505",
                EmissiveStrength = 4,
                EmissiveTint = Color3.new(0.6, 0.7, 0.8),
                ResampleMode = RBX.Enum.ResamplerMode.Pixelated,
                Parent = mesh,
            })

            local surface_clone = surface:Clone()
            expect(surface_clone.Parent):to_be_nil()
            expect(surface_clone.ColorMap):to_be("rbxassetid://501")
            expect(surface_clone.NormalMapContent):to_be("rbxassetid://502")
            expect(surface_clone.AlphaMode):to_be(RBX.Enum.AlphaMode.Opaque)
            expect(surface_clone.Color.G):to_be(0.2)
            expect(surface_clone.EmissiveTint.B):to_be(0.8)
            t.assert_that(rawget(surface_clone,
                    "_surface_appearance_descriptor")
                    ~= rawget(surface, "_surface_appearance_descriptor"),
                "SurfaceAppearance clone reused the source descriptor")

            local mesh_clone = mesh:Clone()
            local clone_handle = rawget(mesh_clone, "_core_handle")
            local clone_surface = mesh_clone:FindFirstChild("Surface")
            expect(clone_handle.SurfaceAppearance):to_be(
                rawget(clone_surface, "_surface_appearance_descriptor"))
            t.assert_that(clone_handle.SurfaceAppearance
                    ~= handle.SurfaceAppearance,
                "MeshPart clone reused the source SurfaceAppearance")
            t.assert_that(clone_handle.SurfaceAppearance.color
                    ~= handle.SurfaceAppearance.color,
                "MeshPart clone aliased SurfaceAppearance.Color")
            t.assert_that(clone_handle.SurfaceAppearance.emissive_tint
                    ~= handle.SurfaceAppearance.emissive_tint,
                "MeshPart clone aliased SurfaceAppearance.EmissiveTint")

            surface.Color = Color3.new(0.9, 0.9, 0.9)
            surface.EmissiveTint = Color3.new(0.1, 0.1, 0.1)
            surface.ColorMap = "rbxassetid://599"
            expect(clone_surface.Color.R):to_be(0.1)
            expect(clone_surface.EmissiveTint.B):to_be(0.8)
            expect(clone_surface.ColorMap):to_be("rbxassetid://501")
        end)
    end)
end

return suite
