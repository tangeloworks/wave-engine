-- engine regression suites. from the repository root:
--
--   RBX_TEST=1 love .          headless; suites that need a window are skipped
--   RBX_TEST=graphics love .   also runs the graphics suites
--
-- RBX_TEST_ONLY=<text> runs only suites whose file name contains <text>.
-- The process exits with status 0 when every selected test passes.

io.stdout:setvbuf("no")

local framework = require("engine/graphics/rbx/tests/framework")
local harness = require("engine/graphics/rbx/tests/harness")

local MODE = os.getenv("RBX_TEST") or "1"
local ONLY = os.getenv("RBX_TEST_ONLY")
local GRAPHICS_MODE = (MODE == "graphics")

local SUITES = {
    "atmosphere_facade_spec",
    "atmosphere_model_spec",
    "camera_source_fidelity_spec",
    "cframe_arithmetic_spec",
    "collision_group_names_ids_spec",
    "compound_pose_spec",
    "constraint_contact_spec",
    "coordinate_spec",
    "coords_spec",
    "cylinder_contact_spec",
    "decorative_pose_spec",
    "directional_shadow_lazy_blend_spec",
    "embedded_mesh_cache_budget_spec",
    "fast_bake_attribute_spec",
    "geometry_spec",
    "gui_mapping_spec",
    "instanced_primitive_shader_spec",
    "legacy_mesh_facade_spec",
    "loading_responsiveness_spec",
    "local_light_cluster_spec",
    "local_light_facade_spec",
    "local_light_uniform_packet_spec",
    "material_primitive_projection_spec",
    "menori_backend_spec",
    "menori_batch_backend_spec",
    "mesh_lod_runtime_spec",
    "p4g_cylinders_spec",
    "p4g_massless_spec",
    "physics_body_storage_spec",
    "physics_invariants_spec",
    "primitive_cull_pixel_spec",
    "primitive_cull_state_spec",
    "primitive_inertia_spec",
    "queries_span_spec",
    "release_mass_force_spec",
    "remote_mesh_renderer_integration_spec",
    "render_bounds_fastpath_spec",
    "runtime_impulse_spec",
    "runtime_part_idempotency_spec",
    "runtime_static_pose_spec",
    "runtime_value_copy_spec",
    "settled_merge_remote_spec",
    "shadow_pose_batch_spec",
    "surface_appearance_facade_spec",
    "surface_appearance_render_spec",
    "surface_appearance_semantics_spec",
    "surface_gui_preload_spec",
    "wedge_box_contact_spec",
    "wedge_contact_spec",
}
local function banner()
    print("")
    print("=======================================================================")
    print(" RBX runtime test suite")
    print("  mode      : " .. MODE .. (GRAPHICS_MODE and "  (graphics enabled)" or "  (headless)"))
    print("  love      : " .. table.concat({ love.getVersion() }, ".", 1, 3))
    print("  jit       : " .. tostring(jit and jit.version or "none")
        .. (jit and jit.status and (jit.status() and " [on]" or " [off]") or ""))
    if ONLY then print("  filter    : " .. ONLY) end
    print("=======================================================================")
end

local function run()
    banner()

    local t0 = love.timer.getTime()
    local selected = 0

    for _, name in ipairs(SUITES) do
        if ONLY and not string.find(name, ONLY, 1, true) then
            -- filtered out; stay quiet
        else
            selected = selected + 1
            local path = "engine/graphics/rbx/tests/suites/" .. name
            local ok, suite = pcall(require, path)
            if not ok then
                framework.results.failed = framework.results.failed + 1
                framework.results.failures[#framework.results.failures + 1] = {
                    suite = name, name = "<load>", err = tostring(suite),
                }
                print("\n  " .. name)
                print("    LOAD ERROR " .. tostring(suite))
            elseif type(suite) ~= "table" or type(suite.run) ~= "function" then
                framework.results.failed = framework.results.failed + 1
                framework.results.failures[#framework.results.failures + 1] = {
                    suite = name, name = "<contract>", err = "suite must return { run = function(t, harness) end }",
                }
                print("\n  " .. name .. "\n    BAD SUITE CONTRACT")
            elseif suite.needs_graphics and not GRAPHICS_MODE then
                framework.skip(name, "needs graphics; run with RBX_TEST=graphics")
            else
                local sok, serr = pcall(suite.run, framework, harness)
                if not sok then
                    framework.results.failed = framework.results.failed + 1
                    framework.results.failures[#framework.results.failures + 1] = {
                        suite = name, name = "<run>", err = tostring(serr),
                    }
                    print("    RUN ERROR " .. tostring(serr))
                end
            end
        end
    end

    assert(selected > 0, "No suite matches RBX_TEST_ONLY")

    print(string.format("\n  elapsed: %.1f ms", (love.timer.getTime() - t0) * 1000))
    local passed = framework.report()
    return passed and 0 or 1
end

local ok, result = pcall(run)
if not ok then
    print("\nTEST RUNNER CRASHED: " .. tostring(result))
    print(debug.traceback())
    result = 2
end

love.event.quit(result)

-- LOVE still needs these to exist for the frame after quit is queued.
function love.update() end

function love.draw() end

return result
