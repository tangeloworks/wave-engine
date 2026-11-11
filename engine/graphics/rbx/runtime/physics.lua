-- clean-room assembly rigid-body sim. rbx-aware adapter, numeric engine lives in runtime/physics/
-- default-off: no step w/o physics_enabled
-- frozen seam: install(rbx, deps), rbx:_* methods, rbx.physics_parity

local Physics = {}

-- undrawn frame would leak records
local DEBUG_RECORD_CAP = 8192

local World = runtime_require("physics/world.lua")
local Assembly = runtime_require("physics/assembly.lua")
local Materials = runtime_require("physics/materials.lua")
local Integrate = runtime_require("physics/integrate.lua")
local Continuous = runtime_require("physics/continuous.lua")
local CFrameMath = runtime_require("physics/cframe_math.lua")
local JointFrames = runtime_require("physics/joint_frames.lua")
local SurfaceWelds = runtime_require("physics/surface_welds.lua")
local Movers = runtime_require("physics/movers.lua")
local DynamicRotate = runtime_require("physics/dynamic_rotate.lua")
local Queries = runtime_require("physics/queries.lua")
local Rope = runtime_require("physics/rope.lua")
local Touch = runtime_require("physics/touch.lua")

-- fuse 2 parts into one assembly, motor6d w/ animated transform goes kinematic follower instead
local RIGID_JOINT_CLASSES = {
    Weld = true,
    WeldConstraint = true,
    Snap = true,
    ManualWeld = true,
    Motor6D = true,
    Motor = true,
}

-- drive child kinematically: part1 = part0.cframe * c0 * transform * c1^-1
local KINEMATIC_JOINT_CLASSES = {
    Motor6D = true,
}

-- printed once when an unsupported joint shows up
local SUPPORTED_JOINT_SUMMARY =
    "Weld, WeldConstraint, ManualWeld, Snap, Motor (rigid), Motor6D (rigid/kinematic), "
    .. "RotateV (kinematic DynamicRotate spin)"

-- glue helpers

-- to_vector3 is a runtime global, guard or headless throws
local function to_vec3(value, fx, fy, fz)
    fx, fy, fz = fx or 0, fy or 0, fz or 0
    if to_vector3 then
        local x, y, z = to_vector3(value, fx, fy, fz)
        return x or fx, y or fy, z or fz
    end
    if type(value) == "table" then
        return tonumber(value.x or value.X or value[1]) or fx,
            tonumber(value.y or value.Y or value[2]) or fy,
            tonumber(value.z or value.Z or value[3]) or fz
    end
    return fx, fy, fz
end

local function invalidate(deps, part, key)
    if deps and deps.invalidate_runtime_part_value_cache then
        deps.invalidate_runtime_part_value_cache(part, key)
    end
end

-- fwd decls so they bind as upvalues not globals
local rigid_edges_from_constraints
local bind_one_assembly
local bind_assembly_poses
local rebuild_no_collision

local function count_set(t)
    if not t then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- no_collision filter map only -- manifold cache uses contact_pair_key below
local function no_collision_key(a, b)
    local sa, sb = tostring(a), tostring(b)
    if sa < sb then
        return sa .. ":" .. sb
    end
    return sb .. ":" .. sa
end

-- keep in sync w/ manifold.lua pair_key
local CONTACT_PAIR_SHIFT = 67108864 -- 2^26
local function contact_pair_key(a, b)
    if a < b then
        return a * CONTACT_PAIR_SHIFT + b
    end
    return b * CONTACT_PAIR_SHIFT + a
end

local function note_filter_clear(world)
    if world then
        world.contact_cache_clears_from_filter_change =
            (world.contact_cache_clears_from_filter_change or 0) + 1
    end
end

-- host-agnostic view -- core never touches rbx types
local function plain_view(part)
    -- Binding/rebinding may admit decoded descriptors without a public setter
    Materials.box_inertia(part, Materials.mass_of(part))
    local cframe = part.CFrame
    return {
        id = part._id,
        _part = part,
        -- immutable, bind reads rotation to seed body orient + member offsets
        CFrameRef = cframe,
        Size = part.Size,
        Shape = part.Shape,
        ClassName = part.ClassName,
        _loaded_from_map = part._loaded_from_map,
        _runtime_dynamic = part._runtime_dynamic,
        Position = {
            x = cframe and (cframe.x or 0) or 0,
            y = cframe and (cframe.y or 0) or 0,
            z = cframe and (cframe.z or 0) or 0,
        },
        Anchored = part.Anchored,
        CanCollide = part.CanCollide,
        -- cantouch/canquery deliberately NOT forwarded (touch/raycast, not contacts)
        CollisionGroup = part.CollisionGroup,
        RotationLocked = part.RotationLocked,
        Massless = part.Massless,
        CustomPhysicalProperties = part.CustomPhysicalProperties,
        -- default friction/elasticity/density when no CustomPhysicalProperties
        Material = part.Material,
        RootPriority = part.RootPriority,
        -- legacy surface-weld fallback, nil on runtime parts = smooth, never auto-welds
        surfaces = {
            top = part.TopSurface, bottom = part.BottomSurface,
            left = part.LeftSurface, right = part.RightSurface,
            front = part.FrontSurface, back = part.BackSurface,
        },
    }
end

-- "roblox_like" is just the diagnostics label, wake/sleep decided by the support bind pass
local function activation_mode_of(self)
    if self.physics_enabled == true then
        return "roblox_like"
    end
    return "off"
end

-- below this = "at rest" for initial wake
local VELOCITY_EPS = 1e-4

local function vec_nonzero(v)
    if type(v) ~= "table" then
        return false
    end
    local x = v.x or v.X or 0
    local y = v.y or v.Y or 0
    local z = v.z or v.Z or 0
    return (x > VELOCITY_EPS or x < -VELOCITY_EPS)
        or (y > VELOCITY_EPS or y < -VELOCITY_EPS)
        or (z > VELOCITY_EPS or z < -VELOCITY_EPS)
end

local function part_velocity_nonzero(part)
    if type(part) ~= "table" then
        return false
    end
    return vec_nonzero(part.AssemblyLinearVelocity) or vec_nonzero(part.Velocity)
        or vec_nonzero(part.AssemblyAngularVelocity) or vec_nonzero(part.RotVelocity)
end

-- baseline wake/sleep post-rebuild, support pass wakes airborne sleepers after
local function apply_activation_mode(self, world)
    local woken    = self._physics_woken_part_ids or {}
    local explicit = self._physics_explicitly_activated_part_ids or {}
    local newly_freed = world._newly_freed_assemblies or {}
    local movers   = self._physics_movers_by_part_id
    local rotate_drivers = self._physics_rotate_followers_by_part_id
    local assemblies = world.assemblies

    local forced = {}
    local runtime_awake = 0
    local velocity_wake = 0
    local static_count = 0

    for ai = 1, #assemblies do
        local asm = assemblies[ai]
        local body = asm.body
        if body and body.is_static then
            static_count = static_count + 1
        elseif body then
            local should_wake = newly_freed[asm] == true
            local is_runtime, is_velocity = false, false
            local members = asm.parts
            for pi = 1, #members do
                local view = members[pi]
                local vid = view.id
                if explicit[vid] or woken[vid] then
                    should_wake = true
                elseif view._loaded_from_map ~= true then
                    should_wake = true
                    is_runtime = true
                elseif part_velocity_nonzero(view._part) then
                    should_wake = true
                    is_velocity = true
                elseif (movers and vid ~= nil and movers[vid])
                    or (rotate_drivers and vid ~= nil and rotate_drivers[vid]) then
                    should_wake = true
                    is_velocity = true
                end
            end
            if should_wake then
                body:wake()
                forced[body] = true
                if is_runtime then
                    runtime_awake = runtime_awake + 1
                elseif is_velocity then
                    velocity_wake = velocity_wake + 1
                end
            else
                -- sleeps until support pass proves airborne
                body:sleep()
            end
        end
    end

    world._forced_awake               = forced
    world.runtime_awake_count         = runtime_awake
    world.loaded_velocity_wake_count  = velocity_wake
    world.static_anchored_assembly_count = static_count
    -- apply_support_aware_initial_state refills these
    world.loaded_supported_sleep_count = 0
    world.loaded_airborne_wake_count   = 0
    world.loaded_uncertain_count       = 0
    world.wake_suppressed_count        = 0
    -- new baseline invalidates prior support classification
    world._support_pass_epoch = nil
end

-- thin slab under the aabb: "static"=on immovable, "sleeping"=on a sleeper, nil=airborne
local SUPPORT_EPS = 0.1              -- slab thickness in studs (> contact_slop, < a part)
local function classify_support(world, asm)
    local body = asm.body
    local bp = world.broadphase
    if not bp or not bp.body_aabb then
        return nil
    end
    local lx, ly, lz, rx, _ry, rz = bp:body_aabb(body)
    local slop = (world.config and world.config.contact_slop) or 0.01
    -- body footprint, just under its bottom
    return bp:query_region_support(lx, ly - SUPPORT_EPS, lz, rx, ly + slop, rz, asm.id)
end

-- once per rebuild: supported/uncertain stay asleep, airborne wakes+falls (budget-capped)
local function apply_support_aware_initial_state(self, world)
    if self.physics_enabled ~= true then
        return
    end
    if world._support_pass_epoch == world.assembly_rebuild_count then
        return
    end
    world._support_pass_epoch = world.assembly_rebuild_count
    world.loaded_supported_sleep_count = 0
    world.loaded_airborne_wake_count   = 0
    world.loaded_uncertain_count       = 0
    if self.physics_collision_enabled ~= true then
        return
    end
    if world.ensure_static_proxies then
        world:ensure_static_proxies()
    end
    if world.active_dirty then
        world:refresh_active()
    end

    local limit = math.max(1, math.floor(tonumber(self.physics_wake_limit) or 100))
    local woken_count = 0
    local suppressed = 0
    local assemblies = world.assemblies
    for ai = 1, #assemblies do
        local asm = assemblies[ai]
        local body = asm.body
        if body and not body.is_static and body.sleeping and not body.kinematic then
            local kind = classify_support(world, asm)
            if kind == "static" then
                world.loaded_supported_sleep_count = world.loaded_supported_sleep_count + 1
                -- stays sleeping: on collidable support
            elseif kind == "sleeping" then
                -- on a sleeper still counts as support -- dont wake these, it cascades the whole jointless map awake -> 0 fps
                world.loaded_uncertain_count = world.loaded_uncertain_count + 1
            else
                world.loaded_airborne_wake_count = world.loaded_airborne_wake_count + 1
                if woken_count < limit then
                    world:wake_body(body)
                    woken_count = woken_count + 1
                else
                    suppressed = suppressed + 1
                end
            end
        end
    end
    world.wake_suppressed_count = suppressed
    if suppressed > 0 and not self._physics_wake_budget_warned then
        self._physics_wake_budget_warned = true
        print(string.format(
            "[physics] wake budget (%d) reached: %d unsupported map assemblies kept sleeping",
            limit, suppressed))
    end
end

-- single source of truth for the snapshot + change-detection, world.lua copies these into world.config
local CONFIG_KEYS = {
    "enabled", "collision_enabled", "activation_mode", "fixed_dt", "max_substeps",
    "max_frame_dt", "velocity_iterations", "position_iterations", "gravity",
    "sleeping_enabled", "sleep_linear_threshold", "sleep_angular_threshold",
    "sleep_time", "budget_ms", "ccd_enabled",
}

-- fills reused scratch `out`, nil knobs -> world defaults
local function config_snapshot(self, out)
    out = out or {}
    out.enabled                 = self.physics_enabled == true
    out.collision_enabled       = self.physics_collision_enabled == true
    out.activation_mode         = activation_mode_of(self)
    out.fixed_dt                = self.physics_fixed_dt or self.physics_max_substep or (1 / 60)
    out.max_substeps            = self.physics_max_substeps or 8
    out.max_frame_dt            = self.physics_max_frame_dt or 0.25
    out.velocity_iterations     = self.physics_solver_iterations
    out.position_iterations     = self.physics_position_iterations
    out.gravity                 = (self.physics_gravity_enabled ~= false)
        and (self._workspace_settings and self._workspace_settings.Gravity or 196.2)
        or 0
    out.sleeping_enabled        = self.physics_sleeping_enabled ~= false
    out.sleep_linear_threshold  = self.physics_sleep_linear_threshold
    out.sleep_angular_threshold = self.physics_sleep_angular_threshold
    out.sleep_time              = self.physics_sleep_time
    out.budget_ms               = self.physics_budget_ms
    out.ccd_enabled             = self.physics_ccd_enabled ~= false
    return out
end

local function config_equal(a, b)
    for i = 1, #CONFIG_KEYS do
        local k = CONFIG_KEYS[i]
        if a[k] ~= b[k] then return false end
    end
    return true
end

local function config_copy(dst, src)
    for i = 1, #CONFIG_KEYS do
        local k = CONFIG_KEYS[i]
        dst[k] = src[k]
    end
    return dst
end

-- only on change: skips a table alloc every frame. value-compare catches a live workspace.Gravity edit w/o setters
local function apply_physics_config(self, world)
    local cfg = config_snapshot(self, self._physics_config_scratch)
    self._physics_config_scratch = cfg
    local applied = self._physics_config_applied
    if applied and config_equal(applied, cfg) then
        return
    end
    world:set_config(cfg)
    self._physics_config_applied = config_copy(applied or {}, cfg)
end

local function ensure_world(self)
    local world = self._physics_world
    if not world then
        world = World.new(config_snapshot(self))
        self._physics_world = world
    end
    return world
end

-- rebuild on dirty topology, writes assembly props back onto real parts
local function ensure_assemblies(self)
    local world = ensure_world(self)
    -- mode change must re-run apply_activation_mode even w/o topology change
    local mode = activation_mode_of(self)
    if world._last_activation_mode ~= mode then
        world._last_activation_mode = mode
        world:mark_assembly_dirty()
    end
    if world.assemblies_built and not world.assembly_dirty then
        return world
    end
    local views = {}
    local parts = self.parts or {}
    for index = 1, #parts do
        local part = parts[index]
        -- _physics_excluded = reparented out of workspace but still in self.parts
        if part and not part._destroyed and not part._physics_excluded and part._id ~= nil then
            views[#views + 1] = plain_view(part)
        end
    end
    -- so a split that frees an anchored part can wake it
    local prev_anchored = {}
    local prev_map = world.part_to_assembly
    if prev_map then
        for pid, asm in pairs(prev_map) do
            if asm and asm.anchored == true then
                prev_anchored[pid] = true
            end
        end
    end

    -- nil edges = nothing to fuse
    local edges, stats = rigid_edges_from_constraints(self)

    -- legacy surface-weld fallback, build-time only
    local surface_weld_count = 0
    if self.physics_surface_welds == true then
        edges, surface_weld_count = SurfaceWelds.append_edges(edges, views)
    end

    world:set_assemblies(Assembly.build(views, { edges = edges }))

    -- diagnostics
    world.assembly_rebuild_count  = (world.assembly_rebuild_count or 0) + 1
    world.rigid_joint_count       = stats and stats.rigid or 0
    world.unsupported_joint_count = stats and stats.unsupported or 0
    world.rotate_v_joint_count    = stats and stats.rotate_v or 0
    world.snap_joint_count        = stats and stats.snap or 0
    world.snap_failed_count       = stats and stats.snap_failed or 0
    world.surface_weld_count      = surface_weld_count

    rebuild_no_collision(self, world)

    -- never silently drop an unsupported joint
    if stats and stats.unsupported > 0 and not self._physics_unsupported_joint_warned then
        self._physics_unsupported_joint_warned = true
        local names = {}
        for cls in pairs(stats.unsupported_classes) do
            names[#names + 1] = tostring(cls)
        end
        table.sort(names)
        print(string.format(
            "[physics] %d unsupported joints skipped (class: %s); supported: %s",
            stats.unsupported, table.concat(names, ", "), SUPPORTED_JOINT_SUMMARY))
    end

    -- so write-back can reconstruct world pose
    bind_assembly_poses(world)

    -- just lost their anchor -> activation force-wakes them. reassigned each rebuild so stale entries cant leak
    local assemblies = world.assemblies
    local newly_freed = {}
    for ai = 1, #assemblies do
        local asm = assemblies[ai]
        if asm.anchored ~= true then
            local members = asm.parts
            for pi = 1, #members do
                if prev_anchored[members[pi].id] then
                    newly_freed[asm] = true
                    break
                end
            end
        end
    end
    world._newly_freed_assemblies = newly_freed

    local physics_deps = Physics._deps
    for ai = 1, #assemblies do
        local asm = assemblies[ai]
        local root_raw = asm.root_part and asm.root_part._part or nil
        local asm_members = asm.parts
        for pi = 1, #asm_members do
            local view = asm_members[pi]
            local actual = view._part
            if actual then
                actual.AssemblyMass = asm.mass
                actual.AssemblyCenterOfMass = { x = asm.com_x, y = asm.com_y, z = asm.com_z }
                actual.AssemblyRootPart = root_raw
                invalidate(physics_deps, actual, "AssemblyMass")
                invalidate(physics_deps, actual, "AssemblyCenterOfMass")
                invalidate(physics_deps, actual, "AssemblyRootPart")
            end
        end
    end

    apply_activation_mode(self, world)

    return world
end

local function dynamic_body_for_part(self, part)
    if type(part) ~= "table" or part._destroyed or part._id == nil then
        return nil
    end
    local world = self._physics_world
    if not world then
        return nil
    end
    local assembly = world.part_to_assembly[part._id]
    if assembly and assembly.body and not assembly.body.is_static then
        return assembly.body
    end
    return nil
end

-- O(1) wake for runtime setters/impulses hitting a SLEEPING body: world:wake_body is a
-- dense-array append + single sleeping-proxy removal, vs Body:wake's active_dirty flag
-- which forces refresh_active -- a scan of EVERY body (~29k statics in a large place) plus a
-- full sleeping-proxy teardown/rebuild. With hundreds of parked NPCs asleep that scan
-- would run per unpark. Setters run from game update, never mid-fixed_step, so the
-- enqueue_wake phase-safety concern does not apply. falls back to Body:wake for the
-- unbound/no-world case (topology rebuild pending)
local function wake_body_fast(body)
    local w = body.world
    if body.sleeping and w ~= nil then
        w:wake_body(body)
    else
        body:wake()
    end
end

-- woken set survives activation-mode rebuilds
local function track_woken(self, part)
    if type(part) == "table" and part._id ~= nil then
        self._physics_woken_part_ids = self._physics_woken_part_ids or {}
        self._physics_woken_part_ids[part._id] = true
    end
end

-- mutate in place, dont realloc -- 4 fresh tables/part/frame was the top GC source w/ many NPCs
local function write_vec3_alias(part, key, x, y, z)
    local t = part[key]
    if type(t) == "table" and getmetatable(t) == nil then
        t.x, t.y, t.z = x, y, z
    else
        part[key] = { x = x, y = y, z = z }
    end
end

local function write_velocity_aliases(deps, part, vx, vy, vz, wx, wy, wz)
    write_vec3_alias(part, "AssemblyLinearVelocity", vx, vy, vz)
    write_vec3_alias(part, "Velocity", vx, vy, vz)
    write_vec3_alias(part, "AssemblyAngularVelocity", wx, wy, wz)
    write_vec3_alias(part, "RotVelocity", wx, wy, wz)
    invalidate(deps, part, "AssemblyLinearVelocity")
    invalidate(deps, part, "AssemblyAngularVelocity")
end

-- a public impulse can be followed by a query or topology edit in the same
-- callback. Rebuilds seed from these aliases, so publish velocity immediately
-- without changing transforms or forcing a render upload
local function publish_impulse_velocity(deps, body)
    body._velocity_publication_dirty=true
    for _,offset in ipairs(body.local_offsets or {}) do
        local part = offset.view and offset.view._part
        if part and not part._destroyed then
            write_velocity_aliases(deps, part, body.vx, body.vy, body.vz, body.wx, body.wy, body.wz)
        end
    end
end

-- dupe of scene.lua's can_update_runtime_part_incrementally (unreachable local there)
local function physics_part_incremental_ok(self, part)
    if type(part) ~= "table" or part._destroyed or part._id == nil then
        return false
    end
    -- per-row upload path, generation+prop_revision checks so a stale ref cant misclassify
    local instanced_ref = part._instanced_ref
    if instanced_ref and instanced_ref.fast == true
        and instanced_ref.generation == (self._instance_generation or 0)
        and instanced_ref.prop_revision == (part._render_prop_revision or 0) then
        return true
    end
    return (part._runtime_dynamic == true or part._promoted_dynamic == true)
        -- anchored ok only for a kinematic follower (moves every frame)
        and (part.Anchored ~= true or part._kinematic_dynamic == true)
end

-- counts fast vs full so "zero full rebuilds" is measurable
local function mark_physics_draw_dirty(self, world, part, deps)
    if physics_part_incremental_ok(self, part) then
        world.transform_updates_from_physics = (world.transform_updates_from_physics or 0) + 1
    else
        world.full_render_rebuilds_from_physics = (world.full_render_rebuilds_from_physics or 0) + 1
    end
    if deps and deps.mark_runtime_part_draw_dirty then
        deps.mark_runtime_part_draw_dirty(self, part)
    end
end

-- per rebuild, off hot path
function rebuild_no_collision(self, world)
    local out = {}
    local runtime = world.no_collision_runtime
    if runtime then
        for key in pairs(runtime) do
            out[key] = true
        end
    end
    local list = self._physics_no_collision_constraints
    if type(list) == "table" then
        local by_ref = self._runtime_part_by_referent or {}
        for i = 1, #list do
            local c = list[i]
            if type(c) == "table" and c.enabled ~= false then
                local pa = c._part0 or by_ref[c.part0_referent]
                local pb = c._part1 or by_ref[c.part1_referent]
                if pa and pb and pa._id ~= nil and pb._id ~= nil and pa._id ~= pb._id then
                    out[no_collision_key(pa._id, pb._id)] = true
                end
            end
        end
    end
    world.no_collision = out
end

-- joint params first, else the axle's powered surface. no input still spins (constant) so a loaded spinner is never dead
local ROTATE_SURFACE_FACES = { "top", "bottom", "front", "back", "left", "right" }
local function resolve_rotate_params(self, joint, axle_part)
    local input_type = joint.surface_input
    local param_a    = joint.param_a
    local param_b    = joint.param_b
    local face       = nil   -- powered surface face (spin-axle normal source)
    if (input_type == nil or param_b == nil) and type(axle_part) == "table" then
        for i = 1, #ROTATE_SURFACE_FACES do
            local f  = ROTATE_SURFACE_FACES[i]
            local si = axle_part[f .. "_surface_input"]
            if si == DynamicRotate.CONSTANT or si == DynamicRotate.SIN then
                input_type = input_type or si
                param_a    = param_a or axle_part[f .. "_param_a"]
                param_b    = param_b or axle_part[f .. "_param_b"]
                face       = f
                break
            end
        end
    end
    if input_type == nil then
        input_type = DynamicRotate.CONSTANT
    end
    return input_type, param_a, param_b, face
end

-- first-capture-wins so a mid-spin rebuild cant overwrite it with a driven pose
local function follower_rest_poses(self, pa, pb)
    local cache = self._physics_follower_rest_cache
    local key = pb and pb._id
    if cache and key ~= nil and cache[key] then
        local e = cache[key]
        return e[1], e[2]
    end
    local p0_rest = (type(pa.CFrame) == "table") and CFrameMath.pack(CFrameMath.unpack(pa.CFrame)) or nil
    local p1_rest = (type(pb.CFrame) == "table") and CFrameMath.pack(CFrameMath.unpack(pb.CFrame)) or nil
    if cache and key ~= nil then
        cache[key] = { p0_rest, p1_rest }
    end
    return p0_rest, p1_rest
end

function rigid_edges_from_constraints(self)
    local by_ref = self._runtime_part_by_referent
    local constraints = self._physics_constraints
    local stats = {
        rigid = 0, kinematic = 0, unsupported = 0, unresolved = 0, rotate_v = 0,
        snap = 0, snap_failed = 0,
        unsupported_classes = {},
    }
    self._physics_motor_followers = {}
    self._physics_rotate_followers = {}
    self._physics_rotate_followers_by_part_id = {}
    self._query_extras_epoch = (self._query_extras_epoch or 0) + 1
    -- persists across rebuilds
    self._physics_follower_rest_cache = self._physics_follower_rest_cache or {}

    if type(constraints) ~= "table" or #constraints == 0 then
        return nil, stats
    end
    by_ref = by_ref or {}

    local edges = nil
    for index = 1, #constraints do
        local joint = constraints[index]
        if type(joint) == "table" and joint.kind == "joint" and joint.enabled ~= false then
            local class_name = joint.class_name
            if RIGID_JOINT_CLASSES[class_name] then
                -- runtime joints carry live refs, parsed ones resolve via referent
                local pa = joint._part0 or by_ref[joint.part0_referent]
                local pb = joint._part1 or by_ref[joint.part1_referent]
                if pa and pb and pa._id ~= nil and pb._id ~= nil and pa._id ~= pb._id then
                    if KINEMATIC_JOINT_CLASSES[class_name] and joint._kinematic == true then
                        -- drive part1 kinematically, dont fuse. rel_j off rest poses ignores a stale c1, else the child flips
                        local followers = self._physics_motor_followers
                        local c0 = joint.c0
                        local p0_rest, p1_rest = follower_rest_poses(self, pa, pb)
                        local rel_j = nil
                        if p0_rest ~= nil and p1_rest ~= nil then
                            rel_j = CFrameMath.mul(CFrameMath.inv(CFrameMath.mul(p0_rest, c0)), p1_rest)
                        end
                        followers[#followers + 1] = {
                            part0 = pa, part1 = pb,
                            c0 = c0, c1 = joint.c1,
                            rel_j = rel_j,
                            transform = joint._transform,
                        }
                        stats.kinematic = stats.kinematic + 1
                    else
                        edges = edges or {}
                        edges[#edges + 1] = { a = pa._id, b = pb._id }
                        stats.rigid = stats.rigid + 1
                        if class_name == "Snap" then stats.snap = stats.snap + 1 end
                    end
                else
                    -- dangling weld (part destroyed): counted, not applied. a Snap here = the visible "part fell away"
                    stats.unresolved = stats.unresolved + 1
                    if class_name == "Snap" then stats.snap_failed = stats.snap_failed + 1 end
                end
            elseif class_name == "RotateV" then
                -- kinematic powered hinge, not rigid fusion
                local pa = joint._part0 or by_ref[joint.part0_referent]
                local pb = joint._part1 or by_ref[joint.part1_referent]
                if pa and pb and pa._id ~= nil and pb._id ~= nil and pa._id ~= pb._id then
                    local it, pna, pnb, face = resolve_rotate_params(self, joint, pa)
                    local p0_rest, p1_rest = follower_rest_poses(self, pa, pb)
                    local followers = self._physics_rotate_followers
                    followers[#followers + 1] = DynamicRotate.make_follower(
                        pa, pb, joint.c0, joint.c1,
                        { input_type = it, param_a = pna, param_b = pnb, base_angle = joint.base_angle,
                          face = face, p0_rest = p0_rest, p1_rest = p1_rest })
                    self._physics_rotate_followers_by_part_id[pb._id] = true
                    stats.rotate_v = stats.rotate_v + 1
                else
                    stats.unresolved = stats.unresolved + 1
                end
            else
                stats.unsupported = stats.unsupported + 1
                stats.unsupported_classes[class_name or "?"] = true
            end
        end
    end
    return edges, stats
end

-- 6 scalars, 0 when absent
local function read_part_velocity(p)
    if type(p) ~= "table" then return 0, 0, 0, 0, 0, 0 end
    local lv = p.AssemblyLinearVelocity or p.Velocity
    local av = p.AssemblyAngularVelocity or p.RotVelocity
    return lv and (tonumber(lv.x or lv.X) or 0) or 0,
        lv and (tonumber(lv.y or lv.Y) or 0) or 0,
        lv and (tonumber(lv.z or lv.Z) or 0) or 0,
        av and (tonumber(av.x or av.X) or 0) or 0,
        av and (tonumber(av.y or av.Y) or 0) or 0,
        av and (tonumber(av.z or av.Z) or 0) or 0
end

-- (qw,qx,qy,qz) from a view's flat cframe, identity if none
local function view_orientation(view)
    local cf = view and view.CFrameRef or nil
    if cf == nil then
        return 1, 0, 0, 0
    end
    return Integrate.quat_from_matrix(
        cf.r00 or 1, cf.r01 or 0, cf.r02 or 0,
        cf.r10 or 0, cf.r11 or 1, cf.r12 or 0,
        cf.r20 or 0, cf.r21 or 0, cf.r22 or 1)
end

-- post-rebuild: seed body orient from root, capture member offsets. only place that reads a part's flat cframe, off hot path
-- bind ONE dynamic assembly's pose/velocity/offsets (extracted so the incremental
-- singleton add can bind without touching every other assembly). returns
-- (orient_checked, orient_preserved) diagnostic deltas, no-op (0, 0) on statics
local ORIENT_TOL = 1e-3
function bind_one_assembly(asm)
    local body = asm.body
    if not body or body.is_static then
        return 0, 0
    end
    local orient_preserved = 0
    local qw, qx, qy, qz = view_orientation(asm.root_part)
    body.qw, body.qx, body.qy, body.qz = qw, qx, qy, qz
    do
        -- diag: catches an identity-reset bug. vs LIVE cframe so a stale cframeref isnt masked
        local rp = asm.root_part
        local pcf = rp and ((rp._part and rp._part.CFrame) or rp.CFrameRef or rp.CFrame) or nil
        local m00, m01, m02, m10, m11, m12, m20, m21, m22 = Integrate.quat_to_matrix(qw, qx, qy, qz)
        local d = math.max(
            math.abs(m00 - (pcf and (pcf.r00 or 1) or 1)),
            math.abs(m01 - (pcf and (pcf.r01 or 0) or 0)),
            math.abs(m02 - (pcf and (pcf.r02 or 0) or 0)),
            math.abs(m10 - (pcf and (pcf.r10 or 0) or 0)),
            math.abs(m11 - (pcf and (pcf.r11 or 1) or 1)),
            math.abs(m12 - (pcf and (pcf.r12 or 0) or 0)),
            math.abs(m20 - (pcf and (pcf.r20 or 0) or 0)),
            math.abs(m21 - (pcf and (pcf.r21 or 0) or 0)),
            math.abs(m22 - (pcf and (pcf.r22 or 1) or 1)))
        if d <= ORIENT_TOL then orient_preserved = 1 end
    end
    local cqw, cqx, cqy, cqz = Integrate.quat_conj(qw, qx, qy, qz)
    local com_x, com_y, com_z = asm.com_x, asm.com_y, asm.com_z

    -- so a 0,100,0 part launches before gravity. root first, else any welded member w/ velocity
    local rp = asm.root_part
    local svx, svy, svz, swx, swy, swz = read_part_velocity((rp and rp._part) or rp)
    if (svx == 0 and svy == 0 and svz == 0) or (swx == 0 and swy == 0 and swz == 0) then
        local members = asm.parts
        for k = 1, #members do
            local mv = members[k]
            local vx, vy, vz, wx, wy, wz = read_part_velocity((mv and mv._part) or mv)
            if svx == 0 and svy == 0 and svz == 0 and (vx ~= 0 or vy ~= 0 or vz ~= 0) then
                svx, svy, svz = vx, vy, vz
            end
            if swx == 0 and swy == 0 and swz == 0 and (wx ~= 0 or wy ~= 0 or wz ~= 0) then
                swx, swy, swz = wx, wy, wz
            end
        end
    end
    body.vx, body.vy, body.vz = svx, svy, svz
    body.wx, body.wy, body.wz = swx, swy, swz

    local members = asm.parts
    local offsets = body.local_offsets
    for k = 1, #members do
        local view = members[k]
        local pos = view.Position or { x = 0, y = 0, z = 0 }
        local dx = (pos.x or 0) - com_x
        local dy = (pos.y or 0) - com_y
        local dz = (pos.z or 0) - com_z
        local lx, ly, lz = Integrate.rotate_vec(cqw, cqx, cqy, cqz, dx, dy, dz)
        local mqw, mqx, mqy, mqz = view_orientation(view)
        local oqw, oqx, oqy, oqz = Integrate.quat_mul(cqw, cqx, cqy, cqz, mqw, mqx, mqy, mqz)
        offsets[k] = {
            view = view,
            lx = lx, ly = ly, lz = lz,
            qw = oqw, qx = oqx, qy = oqy, qz = oqz,
        }
    end
    -- drop stale trailing entries from a bigger previous binding
    for k = #members + 1, #offsets do
        offsets[k] = nil
    end
    return 1, orient_preserved
end

function bind_assembly_poses(world)
    local assemblies = world.assemblies
    local orient_checked, orient_preserved = 0, 0
    for ai = 1, #assemblies do
        local checked, preserved = bind_one_assembly(assemblies[ai])
        orient_checked = orient_checked + checked
        orient_preserved = orient_preserved + preserved
    end
    world.orientation_checked_count = orient_checked
    world.orientation_preserved_count = orient_preserved
end

-- hot path: scalar locals, no temp tables. only alloc is the cframe per moved part
local function write_back_body(self, world, deps, body)
    -- Controllers and touch sensors read published poses between substeps
    -- Reusing the same publication at the next boundary avoids invalidating
    -- facade caches and render geometry three times for one physical pose
    local published = body._published_state
    local same_pose=published and published[1] == body.com_x and published[2] == body.com_y
        and published[3] == body.com_z and published[4] == body.qw
        and published[5] == body.qx and published[6] == body.qy and published[7] == body.qz
    if same_pose and not body._velocity_publication_dirty
        and published[8] == body.vx and published[9] == body.vy and published[10] == body.vz
        and published[11] == body.wx and published[12] == body.wy and published[13] == body.wz then
        return
    end
    published = published or {}
    body._published_state = published
    published[1], published[2], published[3] = body.com_x, body.com_y, body.com_z
    published[4], published[5], published[6], published[7] = body.qw, body.qx, body.qy, body.qz
    published[8], published[9], published[10] = body.vx, body.vy, body.vz
    published[11], published[12], published[13] = body.wx, body.wy, body.wz
    body._velocity_publication_dirty=nil
    if same_pose then
        -- External setters/impulses can publish a velocity that contacts consume
        -- back to the previous physical state. its facade aliases still need
        -- correction even though that pose needs no new CFrame or draw upload
        for k=1,#body.local_offsets do
            local part=body.local_offsets[k].view and body.local_offsets[k].view._part
            if part and not part._destroyed then
                write_velocity_aliases(deps,part,body.vx,body.vy,body.vz,body.wx,body.wy,body.wz)
            end
        end
        return
    end
    local qw, qx, qy, qz = body.qw, body.qx, body.qy, body.qz
    local r00, r01, r02, r10, r11, r12, r20, r21, r22 = Integrate.quat_to_matrix(qw, qx, qy, qz)
    local cx, cy, cz = body.com_x, body.com_y, body.com_z
    local vx, vy, vz = body.vx, body.vy, body.vz
    local wx, wy, wz = body.wx, body.wy, body.wz
    local offsets = body.local_offsets
    for k = 1, #offsets do
        local o = offsets[k]
        local part = o.view and o.view._part or nil
        if part and not part._destroyed then
            local lx, ly, lz = o.lx, o.ly, o.lz
            local px = cx + r00 * lx + r01 * ly + r02 * lz
            local py = cy + r10 * lx + r11 * ly + r12 * lz
            local pz = cz + r20 * lx + r21 * ly + r22 * lz
            local mqw, mqx, mqy, mqz = Integrate.quat_mul(qw, qx, qy, qz, o.qw, o.qx, o.qy, o.qz)
            local m00, m01, m02, m10, m11, m12, m20, m21, m22 = Integrate.quat_to_matrix(mqw, mqx, mqy, mqz)
            part.CFrame = CFrame.from_matrix(px, py, pz, m00, m01, m02, m10, m11, m12, m20, m21, m22)
            write_vec3_alias(part, "AssemblyCenterOfMass", cx, cy, cz)
            invalidate(deps, part, "CFrame")
            -- woken loaded part is still in the static mega-batch, promote on first move (one full rebuild, then transform-only)
            if part._loaded_from_map == true and part._promoted_dynamic ~= true
                and deps and deps.promote_loaded_part_to_dynamic then
                deps.promote_loaded_part_to_dynamic(self, part)
            end
            mark_physics_draw_dirty(self, world, part, deps)
            write_velocity_aliases(deps, part, vx, vy, vz, wx, wy, wz)
        end
    end
end

local function write_back_active(self, world, deps)
    for i = 1, world.active_count do
        write_back_body(self, world, deps, world.active_bodies[i])
    end
    -- publish the final solver pose/zero velocities before static demotion
    -- a body woken again within this update was already published above
    local pending = world.sleep_pose_publications
    if pending then
        for i = 1, #pending do
            local body = pending[i]
            if body.world == world and body.sleeping and not body.is_static then
                write_back_body(self, world, deps, body)
            end
        end
        world:clear_sleep_pose_publications()
    end
end

-- fold settled parts back into the static batch, else they keep paying dynamic-chunk cost
local function demote_settled_promoted_parts(self, world, deps)
    if self.physics_demote_on_sleep == false then return 0 end
    if not (deps and deps.demote_loaded_part_to_static) then return 0 end
    if (self._promoted_loaded_part_count or 0) <= 0 then return 0 end
    local promoted = self._promoted_loaded_parts
    if type(promoted) ~= "table" then return 0 end
    local map = world.part_to_assembly
    if not map then return 0 end
    -- collect first: demote removes the entry, cant mutate `promoted` mid-iterate
    local settled = nil
    for pid, part in pairs(promoted) do
        -- never demote a kinematic follower: sleeping but cframe rewritten every frame -> re-promote thrash
        if type(part) == "table" and not part._destroyed and part._promoted_dynamic == true
            and part._kinematic_dynamic ~= true then
            local asm = map[pid]
            local body = asm and asm.body
            if body and not body.is_static and body.sleeping == true then
                settled = settled or {}
                settled[#settled + 1] = part
            end
        end
    end
    if not settled then return 0 end
    for i = 1, #settled do
        deps.demote_loaded_part_to_static(self, settled[i])
    end
    self._physics_auto_demote_count = (self._physics_auto_demote_count or 0) + #settled
    return #settled
end

-- kill plane (default -500) so parts dont free-fall forever. active bodies only, ~free
local function apply_fallen_parts_destroy_height(self, world)
    local ws = self._workspace_settings
    local height = ws and tonumber(ws.FallenPartsDestroyHeight)
    if height == nil or not self._destroy_runtime_part then return 0 end
    local active = world.active_bodies
    local count = world.active_count or 0
    local doomed
    local falling = 0
    for i = 1, count do
        local body = active[i]
        if body and not body.is_static then
            if (body.vy or 0) < -1 then falling = falling + 1 end -- diag: moving down
            if body.com_y < height then
                local offsets = body.local_offsets
                for k = 1, #offsets do
                    local view = offsets[k] and offsets[k].view
                    local part = view and view._part
                    if part and not part._destroyed then
                        doomed = doomed or {}
                        doomed[#doomed + 1] = part
                    end
                end
            end
        end
    end
    world.falling_body_count = falling
    if not doomed then return 0 end
    for i = 1, #doomed do
        self:_destroy_runtime_part(doomed[i])
    end
    self._fallen_parts_destroyed_count = (self._fallen_parts_destroyed_count or 0) + #doomed
    return #doomed
end

-- rigid-joint lifecycle + motor6d follower helpers

-- map/instance referent, or the part itself for runtime parts
local function referent_of_part(part)
    if type(part) ~= "table" then
        return part
    end
    return part._map_referent or part._referent or part
end

-- rotation -> unit quat (bodygyro goal), identity if no rotation matrix
local function cframe_goal_quat(cf)
    if type(cf) ~= "table" or cf.r00 == nil then
        return 1, 0, 0, 0
    end
    return Integrate.quat_from_matrix(
        cf.r00, cf.r01 or 0, cf.r02 or 0,
        cf.r10 or 0, cf.r11 or 1, cf.r12 or 0,
        cf.r20 or 0, cf.r21 or 0, cf.r22 or 1)
end

-- driven LIVE by the datamodel bridge, parsed path must skip these or it double-applies a stale value
local INSTANCE_BRIDGED_MOVER_CLASSES = {
    BodyForce = true,
    BodyThrust = true,
    BodyVelocity = true,
    BodyAngularVelocity = true,
    BodyPosition = true,
    BodyGyro = true,
}

-- parsed legacy body* movers under "parsed:", rebuilt every step, bridged classes live under "inst:"
local function sync_movers(self, world)
    if not world or not world.movers then
        return
    end
    local movers = self._physics_movers
    -- common case: nothing to do
    if (type(movers) ~= "table" or #movers == 0) and not self._physics_parsed_movers_synced then
        if type(self._physics_movers_by_part_id) ~= "table" then
            self._physics_movers_by_part_id = {}
        end
        return
    end
    world.movers:clear_prefix("parsed:")
    local by_part = {}
    self._physics_movers_by_part_id = by_part
    self._physics_parsed_movers_synced = false
    if type(movers) ~= "table" then
        return
    end
    local by_ref = self._runtime_part_by_referent or {}
    for i = 1, #movers do
        local src = movers[i]
        if type(src) == "table" and src.enabled ~= false
            and not INSTANCE_BRIDGED_MOVER_CLASSES[src.class_name] then
            local part = src._part or by_ref[src.parent_referent]
            local pid = type(part) == "table" and part._id or nil
            if pid ~= nil then
                if src.class_name == "BodyGyro" and src.goal_quat == nil then
                    local qw, qx, qy, qz = cframe_goal_quat(src.cframe)
                    src.goal_quat = { qw = qw, qx = qx, qy = qy, qz = qz }
                end
                local rec = Movers.from_legacy(src, pid, "parsed:" .. i)
                if rec then
                    world.movers:add(rec)
                    by_part[pid] = true
                    self._physics_parsed_movers_synced = true
                end
            end
        end
    end
end

-- selector = record, referent, name, or part pair. returns (joint, index)
local function find_in_list(constraints, selector)
    if type(constraints) ~= "table" or selector == nil then
        return nil, nil
    end
    for i = 1, #constraints do
        if constraints[i] == selector then
            return constraints[i], i
        end
    end
    -- joint's own referent (datamodel destroy/disable path)
    local referent = type(selector) == "table" and selector.referent or nil
    if referent ~= nil then
        for i = 1, #constraints do
            if constraints[i].referent == referent then
                return constraints[i], i
            end
        end
    end
    local name = (type(selector) == "string" and selector)
        or (type(selector) == "table" and (selector.name or selector.Name)) or nil
    if name ~= nil then
        for i = 1, #constraints do
            if constraints[i].name == name then
                return constraints[i], i
            end
        end
    end
    if type(selector) == "table" then
        local ra = selector.part0_referent or selector.a
            or referent_of_part(selector.part0 or selector.Part0)
        local rb = selector.part1_referent or selector.b
            or referent_of_part(selector.part1 or selector.Part1)
        if ra ~= nil and rb ~= nil then
            for i = 1, #constraints do
                local c = constraints[i]
                if (c.part0_referent == ra and c.part1_referent == rb)
                    or (c.part0_referent == rb and c.part1_referent == ra) then
                    return c, i
                end
            end
        end
    end
    return nil, nil
end

local function find_constraint(self, selector)
    return find_in_list(self._physics_constraints, selector)
end

local function find_no_collision_constraint(self, selector)
    return find_in_list(self._physics_no_collision_constraints, selector)
end

-- after any joint mutation, re-arms the unsupported-joint warning
local function mark_joint_topology_dirty(self)
    self._physics_unsupported_joint_warned = false
    self._physics_assembly_dirty = true
    local world = self._physics_world
    if world then
        world:mark_assembly_dirty()
    end
end

-- renderer cframe or plain {x,y,z} -> flat cframe
local function to_flat_cframe(value)
    if type(value) ~= "table" then
        return CFrameMath.identity()
    end
    if value.r00 ~= nil then
        return value
    end
    return CFrameMath.pack(
        tonumber(value.x or value.X) or 0,
        tonumber(value.y or value.Y) or 0,
        tonumber(value.z or value.Z) or 0,
        1, 0, 0, 0, 1, 0, 0, 0, 1)
end

-- runs after write_back_active so the parent pose is final
local function apply_motor_followers(self, world, deps)
    local followers = self._physics_motor_followers
    if not followers or #followers == 0 then
        return
    end
    for i = 1, #followers do
        local f = followers[i]
        local p0, p1 = f.part0, f.part1
        if type(p0) == "table" and type(p1) == "table"
            and not p0._destroyed and not p1._destroyed and p0.CFrame ~= nil then
            -- rest-relative when a rest pose was captured (no flip), else legacy absolute
            local r
            if f.rel_j ~= nil then
                r = CFrameMath.motor6d_rest_relative(p0.CFrame, f.c0, f.transform, f.rel_j)
            else
                r = CFrameMath.motor6d_part1_cframe(p0.CFrame, f.c0, f.transform, f.c1)
            end
            p1.CFrame = CFrame.from_matrix(
                r.x, r.y, r.z,
                r.r00, r.r01, r.r02,
                r.r10, r.r11, r.r12,
                r.r20, r.r21, r.r22)
            invalidate(deps, p1, "CFrame")
            -- keep body out of the integrator so gravity/contacts cant fight the driven pose
            local asm = world.part_to_assembly and world.part_to_assembly[p1._id]
            if asm and asm.body and not asm.body.is_static and not asm.body.sleeping then
                asm.body.kinematic = true
                world:sleep_body(asm.body)
            end
            if p1._loaded_from_map == true and p1._promoted_dynamic ~= true
                and deps and deps.promote_loaded_part_to_dynamic then
                deps.promote_loaded_part_to_dynamic(self, p1, true) -- driven: allow anchored kinematic follower
            end
            mark_physics_draw_dirty(self, world, p1, deps)
        end
    end
end

-- runs after write_back_active + apply_motor_followers, child never integrated so it cant detach
local function apply_rotate_joints(self, world, deps)
    local followers = self._physics_rotate_followers
    if not followers or #followers == 0 then
        return
    end
    local dt = self._physics_last_dt or 0
    local t = 0
    if world and world.config then
        t = (world.step_index or 0) * (world.config.fixed_dt or (1 / 60))
    end
    for i = 1, #followers do
        local rec = followers[i]
        local p0, p1 = rec.part0, rec.part1
        if type(p0) == "table" and type(p1) == "table"
            and not p0._destroyed and not p1._destroyed and p0.CFrame ~= nil then
            local r = DynamicRotate.advance(rec, dt, t)
            p1.CFrame = CFrame.from_matrix(
                r.x, r.y, r.z,
                r.r00, r.r01, r.r02,
                r.r10, r.r11, r.r12,
                r.r20, r.r21, r.r22)
            invalidate(deps, p1, "CFrame")
            -- same as motor6d follower: out of the integrator, no stale proxy
            local asm = world.part_to_assembly and world.part_to_assembly[p1._id]
            if asm and asm.body and not asm.body.is_static and not asm.body.sleeping then
                asm.body.kinematic = true
                world:sleep_body(asm.body)
            end
            if p1._loaded_from_map == true and p1._promoted_dynamic ~= true
                and deps and deps.promote_loaded_part_to_dynamic then
                deps.promote_loaded_part_to_dynamic(self, p1, true) -- driven: allow anchored kinematic follower
            end
            mark_physics_draw_dirty(self, world, p1, deps)
        end
    end
end

-- install

-- Touched/TouchEnded diff off the manifold cache. queued so a callback cant mutate parts mid-step, both ends need CanTouch
local function run_touch_events(self, world, advanced)
    local listeners = self._touch_listener_ids
    if not listeners or next(listeners) == nil then
        -- drop stale active set so a later connect starts clean
        if self._touch_active_pairs and next(self._touch_active_pairs) then
            self._touch_active_pairs = {}
        end
        return
    end
    local cache = world.manifold_cache
    local manifolds = cache and cache.manifolds
    if not manifolds then
        return
    end
    local prev = self._touch_active_pairs or {}
    local queue = self._pending_touch_events or {}
    if not advanced and self._touch_scan_step == world.step_index
        and self._touch_scan_revision == (self._touch_listener_revision or 0) then
        -- no simulation means no new contacts. preserve existing pairs in
        -- place, while still delivering removals/CanTouch changes immediately
        -- this avoids scanning every awake manifold and allocating a new set
        -- on hundreds of presentation-only frames per second
        for key,pair in pairs(prev) do
            local a,b=pair.a,pair.b
            if not a or not b or a._destroyed or b._destroyed
                or a.CanTouch==false or b.CanTouch==false then
                if a and b then queue[#queue+1]={a=a,b=b,phase="TouchEnded"} end
                prev[key]=nil
            end
        end
        self._pending_touch_events=queue
        world.touch_idle_reuse_count=(world.touch_idle_reuse_count or 0)+1
        return
    end
    local current = {}

    -- touching = manifold in cache. prune grace = free hysteresis, so a resting contact doesnt flicker
    for key, m in pairs(manifolds) do
        local a_id, b_id = m.part_a_id, m.part_b_id
        if a_id and b_id and (listeners[a_id] or listeners[b_id]) then
            local pa = m.view_a and m.view_a._part
            local pb = m.view_b and m.view_b._part
            if pa and pb and not pa._destroyed and not pb._destroyed
                and pa.CanTouch ~= false and pb.CanTouch ~= false then
                current[key] = prev[key] or { a = pa, b = pb }
                if not prev[key] then
                    queue[#queue + 1] = { a = pa, b = pb, phase = "Touched" }
                end
            end
        end
    end

    -- Sensors run only after actual simulation, a CFrame assignment followed by
    -- update(0) is not a physical touch. Spatial hash candidates are followed by
    -- the same shape narrowphase used by the solver, without collision filtering
    if advanced then
        Touch.collect(self, world, current, prev, queue, contact_pair_key)
    else
        for key, pair in pairs(prev) do
            if not current[key] and pair.a and pair.b
                and not pair.a._destroyed and not pair.b._destroyed
                and pair.a.CanTouch ~= false and pair.b.CanTouch ~= false then
                current[key] = pair
            end
        end
    end

    -- TouchEnded fires even if one side died mid-contact, the flush skips a side w/ no live instance
    for key, pair in pairs(prev) do
        if not current[key] then
            local pa, pb = pair.a, pair.b
            if pa and pb then
                queue[#queue + 1] = { a = pa, b = pb, phase = "TouchEnded" }
            end
        end
    end

    self._touch_active_pairs = current
    self._pending_touch_events = queue
    self._touch_scan_step = world.step_index
    self._touch_scan_revision = self._touch_listener_revision or 0
end

-- parts not reliably hashed yet: just-registered dynamics + kinematic followers. fills reused `out`
local function collect_extra_query_parts(self, out)
    local n = 0
    -- NOT already-hashed dynamics -- the DDA finds those. rescanning them here made every raycast O(all dynamics) (~1500 on a big map)
    local pending = self._physics_pending_query_parts
    if pending then
        for _, part in pairs(pending) do
            if type(part) == "table" and not part._destroyed and part._workspace_active~=false then
                n = n + 1; out[n] = part
            end
        end
    end
    local mf = self._physics_motor_followers
    if mf then
        for i = 1, #mf do
            local p1 = mf[i].part1
            if type(p1) == "table" and not p1._destroyed and p1._workspace_active~=false then
                n = n + 1; out[n] = p1
            end
        end
    end
    local rf = self._physics_rotate_followers
    if rf then
        for i = 1, #rf do
            local p1 = rf[i].part1
            if type(p1) == "table" and not p1._destroyed and p1._workspace_active~=false then
                n = n + 1; out[n] = p1
            end
        end
    end
    for i = n + 1, #out do out[i] = nil end
    return out
end

-- Impact-wake only fires on closing contacts. a collider removed in place must wake a
-- sleeper that may have been resting on it or the body would remain suspended
local function wake_sleepers_overlapping(world, minx, miny, minz, maxx, maxy, maxz, excluded_id)
    local bp = world.broadphase
    local proxies = bp and bp.sleeping_proxies
    if not proxies then return end
    for id, proxy in pairs(proxies) do
        local a = proxy.aabb
        if id ~= excluded_id and a and a[4] >= minx and a[1] <= maxx
            and a[5] >= miny and a[2] <= maxy
            and a[6] >= minz and a[3] <= maxz then
            -- the proxy id is the assembly id. resolve directly so even a proxy whose
            -- cells were saturated out of the spatial hash can still be woken safely
            local asm = world.assemblies_by_id and world.assemblies_by_id[id]
            local body = asm and asm.body
            -- wake_body removes the current proxy, deleting a current pairs() key is legal
            if body then world:wake_body(body) end
        end
    end
end

-- conservative, rotation-safe wake region around one raw part
local function part_wake_box(part, margin)
    local cf = part.CFrame
    local x = cf and (cf.x or 0) or 0
    local y = cf and (cf.y or 0) or 0
    local z = cf and (cf.z or 0) or 0
    local s = part.Size
    local m = (s and math.max(s.x or 1, s.y or 1, s.z or 1) or 2) * 0.5 + (margin or 1)
    return x - m, y - m, z - m, x + m, y + m, z + m
end

local function constraint_references_part(rec, part, by_ref)
    if type(rec) ~= "table" then return false end
    local pa = rec._part0 or by_ref[rec.part0_referent]
    local pb = rec._part1 or by_ref[rec.part1_referent]
    return pa == part or pb == part
end

local function list_references_part(list, part, by_ref)
    if type(list) ~= "table" then return false end
    for i = 1, #list do
        if constraint_references_part(list[i], part, by_ref) then return true end
    end
    return false
end

local function follower_references_part(list, part)
    if type(list) ~= "table" then return false end
    for i = 1, #list do
        local follower = list[i]
        if follower and (follower.part0 == part or follower.part1 == part) then return true end
    end
    return false
end

local function no_collision_map_references_part(map, part_id)
    if type(map) ~= "table" or part_id == nil then return false end
    for key in pairs(map) do
        if type(key) == "string" then
            local split = string.find(key, ":", 1, true)
            if split and (tonumber(string.sub(key, 1, split - 1)) == part_id
                or tonumber(string.sub(key, split + 1)) == part_id) then
                return true
            end
        end
    end
    return false
end

-- Semantic guards owned by the RBX adapter. the World helper separately audits every
-- world-owned topology reference before it mutates anything
local function singleton_removal_has_dependency(self, world, part, body)
    local part_id = part and part._id
    if not part_id or not body or body.kinematic then return true end
    local by_ref = self._runtime_part_by_referent or {}
    if list_references_part(self._physics_constraints, part, by_ref)
        or list_references_part(self._physics_no_collision_constraints, part, by_ref)
        or follower_references_part(self._physics_motor_followers, part)
        or follower_references_part(self._physics_rotate_followers, part)
        or (self._physics_movers_by_part_id and self._physics_movers_by_part_id[part_id])
        or (self._physics_rotate_followers_by_part_id
            and self._physics_rotate_followers_by_part_id[part_id])
        or (world.movers and world.movers.has_part and world.movers:has_part(part_id))
        or no_collision_map_references_part(world.no_collision_runtime, part_id)
        or no_collision_map_references_part(world.no_collision, part_id) then
        return true
    end
    return false
end

function Physics.install(RBX, deps)
    Physics._deps = deps
    deps = deps or {}

    RBX.PHYSICS_PARITY = {
        supported = {
            "Clean modular skeleton: world / body / assembly / shape / materials / integrate / debug",
            "Fixed-timestep accumulator with capped substeps",
            "Gravity + semi-implicit Euler integration of rigid bodies (linear + angular)",
            "Orientation integrated as a renormalized unit quaternion (NaN/zero-norm guarded)",
            "Active bodies kept in a dense array; static and sleeping bodies are not integrated",
            "Physics movement writes part transforms only, through the render fast-path (zero full rebuilds)",
            "Assembly build from part topology with rigid-joint (weld) fusion via union-find edges",
            "Welded parts move as one rigid body; per-member local offsets reconstruct world poses",
            "Joint classification: Weld / WeldConstraint / ManualWeld / Snap / Motor (rigid) / Motor6D fuse parts into one assembly; unsupported joint classes (RotateV, constraint joints) are counted and warned once, never silently mis-fused",
            "Runtime joint lifecycle: disable / remove / add a joint marks topology dirty, rebuilds, and splits the assembly via union-find; pieces that lose their anchor on a split wake",
            "Motor6D kinematic Transform: a non-identity (animated) Transform drives the child kinematically (Part0.CFrame * C0 * Transform * C1^-1) through the cheap transform path; identity Transform stays rigid-fused",
            "Legacy surface-weld fallback (opt-in physics_surface_welds): parts whose touching faces carry compatible SurfaceTypes (Studs/Inlet, Weld, Glue, Universal) fuse at build time only",
            "Assembly-topology diagnostics: rigid_joint_count, unsupported_joint_count, assembly_rebuild_count, topology_dirty_count, largest_assembly_part_count, anchored_static / dynamic_awake / dynamic_sleeping assembly counts",
            "Anchored (or any-member-anchored) assemblies are static and never integrated",
            "Per-assembly mass / center-of-mass; standalone solid Box/Ball/native-X Cylinder inertia; multi-part root-box inertia approximation",
            "Read-only diagnostics snapshot, populated even when physics is disabled",
            "Velocity / RotVelocity <-> AssemblyLinearVelocity / AssemblyAngularVelocity aliases wired",
            "Default-off: no step unless physics_enabled, no collision unless physics_collision_enabled",
            "Spatial-hash broadphase: static proxies inserted once, dynamic proxies upserted per step for active bodies only; gated by physics_collision_enabled",
            "Broadphase diagnostics: static_proxy_count, dynamic_proxy_count, dirty_proxy_count, proxy_upsert_count, candidate_check_count, broadphase_pair_count, broadphase_ms",
            "Narrowphase: sphere-sphere, sphere-box, box-box; native X-cylinder/Ball/Block/Cylinder contacts in tested envelope with explicit bounded-query errors; wedge/mesh/other unsupported routes remain approximated; gated by physics_collision_enabled",
            "Persistent contact manifolds: stable sorted pair key, contact normal/point/penetration, cached normal+tangent impulses (warm-start), lifetime counter, inactive prune, bounded LRU cache",
            "Contact invalidation: parts destroyed (lazy + rebuild-clear), CanCollide off, CollisionGroup change, and no-collision filter all drop cached contacts",
            "Narrowphase diagnostics: manifold_cache_count, manifold_active_count, manifold_pruned_count, contact_count, narrowphase_ms",
            "BasePart property bridge: CFrame/Position mark transform dirty; Size marks shape+mass+broadphase dirty; Anchored marks topology+activation dirty; CanCollide/CollisionGroup mark collision dirty; Massless marks mass+assembly dirty; RootPriority marks assembly dirty; CustomPhysicalProperties marks mass dirty",
            "Shape-aware mass: Ball (sphere 4/3*pi*r^3), Cylinder (pi*r^2*h), Wedge/Mesh/Truss (box fallback)",
            "Material properties: friction, elasticity, friction_weight, elasticity_weight from CustomPhysicalProperties",
            "AssemblyMass / AssemblyCenterOfMass / AssemblyRootPart updated on each assembly rebuild",
            "ApplyImpulse / ApplyImpulseAtPosition / ApplyAngularImpulse drive real assembly motion",
            "idle map assemblies sleep until motion, lost support, an impulse or an explicit wake requires simulation",
            "map wakeups are capped per rebuild; diagnostics report wake_limit and wake_suppressed_count",
            "wake_part / wake_assembly / sleep_assembly / activate_runtime_part internal APIs",
            "Woken-part tracking: nonzero velocity set, impulse applied, or explicit activation survives assembly rebuilds",
            "PGS contact solver: sequential-impulse velocity solve (push-only normal per manifold point + Coulomb-clamped centroid friction) with warm-start, then NGS/split-impulse position correction; gated by physics_collision_enabled (velocity_iterations=0 = detection-only)",
            "Restitution: per-contact elasticity with an adaptive bounce threshold so resting bodies settle; solver diagnostics (solver_ms, contacts, velocity/position iterations)",
            "Axis-aligned multi-point box-box manifolds: up to 4 coplanar face-clip points (per-point feature ids, warm-started) so flat boxes resist tipping",
            "Mover constraints: legacy Body* (Force/Thrust/Velocity/AngularVelocity/Position/Gyro) plus the modern force/velocity/PD kinds (VectorForce, Torque, LineForce, LinearVelocity, AngularVelocity, AlignPosition, AlignOrientation) via the runtime mover API; force/torque caps; movers wake their targets",
            "Automatic sleeping: linear+angular threshold with a sleep timer, incremental dense active set, sleeping broadphase proxies (awake bodies still rest on/wake sleepers), impact-wake, and a wall-clock substep budget (drops the backlog instead of freezing)",
            "Collision groups: a register + group-vs-group collidable matrix, plus per-pair NoCollisionConstraint; both filter narrowphase and drop cached contacts on change",
        },
        unsupported = {
            "Oriented-box SAT: rotated box pairs / tilted ramps fall back to a single contact point (the multi-point manifold is axis-aligned only), so there is no tip resistance when tilted",
            "CCD: a body moving faster than ~its own thickness per step can tunnel a thin collider (physics_ccd_enabled is reserved / no-op)",
            "Momentum transfer across the wake boundary is not conserved at the instant of impact, and a wake spreads through a pile one contact-layer per step (no instant island flood-fill)",
            "A sleeper is not auto-woken when the body it rests on is destroyed/teleported",
            "Friction is zero-lever-arm (linear): it stops a sliding box but cannot spin a body down (e.g. a top)",
            "Motor6D dynamics: an animated Motor6D child is kinematic-only (no gravity/collision feedback) and single-level; full articulated-body solving is future work",
            "Topology rebuild is whole-world (not island-scoped); a removed joint that splits a moving assembly resets the freed pieces' velocity until cross-rebuild state carry-over lands",
            "Surface-weld adjacency is axis-aligned only (rotated mates skipped -- never a false weld); motion surfaces (Hinge/Motor) never weld",
            "Modern mover/constraint INSTANCES and their Attachments are not parsed from a loaded map yet (they come only via the runtime mover API / tests); physics_broadphase_cell_size is reserved / no-op",
        },
        todos = {
            "Oriented-box SAT + incident-face clipping for rotated multi-point manifolds (the data path already supports <=4 feature-id'd points)",
            "Real CCD (swept-AABB TOI) so physics_ccd_enabled becomes meaningful",
            "Momentum transfer + island flood-fill across the wake boundary; auto-wake a sleeper when its support is removed",
            "Parse modern mover/constraint instances (VectorForce, LinearVelocity, AlignPosition, Attachments, ...) from maps; articulated/dynamic Motor6D",
            "Multi-part shape inertia aggregation with the parallel-axis theorem; standalone primitive moments already use the current rotated body tensor",
            "Carry velocity/orientation across assembly rebuilds (island-scoped topology rebuild)",
        },
    }

    function RBX:_ensure_physics_world()
        return ensure_world(self)
    end

    -- spatial-query entrypoints, return *core parts*, datamodel maps them to user-facing instances
    -- flush pending topology so new parts are indexed, linear scan when physics is off
    local function query_world_and_extras(self, opts)
        opts.fallback_parts = self.parts
        if self.physics_enabled == true then
            -- topology first: a rebuild re-derives the follower lists the extras scan reads
            local world = ensure_assemblies(self)
            -- epoch-cached: reuse the scratch array instead of rescanning per query
            local epoch = self._query_extras_epoch or 0
            local scratch = self._query_extra_scratch
            if scratch == nil then
                scratch = {}
                self._query_extra_scratch = scratch
            end
            if self._query_extras_cached_epoch ~= epoch then
                collect_extra_query_parts(self, scratch)
                self._query_extras_cached_epoch = epoch
            end
            opts.extra_parts = scratch
            return world
        end
        return self._physics_world
    end

    -- true if sleeping or a manifold pushes up steeper than min_up. nil = cant answer, caller should raycast
    function RBX:part_is_supported(part, min_up)
        if self.physics_enabled ~= true then
            return nil
        end
        if type(part) == "table" and rawget(part, "_core_handle") then
            part = rawget(part, "_core_handle")
        end
        local part_id = type(part) == "table" and part._id or part
        if part_id == nil then
            return nil
        end
        local world = self._physics_world
        local asm = world and world.part_to_assembly and world.part_to_assembly[part_id]
        local body = asm and asm.body
        if not body then
            return nil
        end
        if body.sleeping and not body.kinematic then
            return true
        end
        local cache = world.manifold_cache
        local contacts = cache and cache.by_part and cache.by_part[part_id]
        if not contacts then
            return false
        end
        min_up = tonumber(min_up) or 0.5
        for _, m in pairs(contacts) do
            if m.points and #m.points > 0 and (m.inactive_frames or 0) == 0 then
                -- normal points a->b, so "supported" = -ny for a, +ny for b
                if m.part_a_id == part_id then
                    if (m.normal_y or 0) <= -min_up then return true end
                elseif (m.normal_y or 0) >= min_up then
                    return true
                end
            end
        end
        return false
    end

    -- wall-like face most opposing (dirx,dirz) -> unit normal. zero-alloc, lets a controller slide along walls
    function RBX:part_wall_normal(part, dirx, dirz, max_ny)
        if self.physics_enabled ~= true then
            return nil
        end
        if type(part) == "table" and rawget(part, "_core_handle") then
            part = rawget(part, "_core_handle")
        end
        local part_id = type(part) == "table" and part._id or part
        if part_id == nil then
            return nil
        end
        local world = self._physics_world
        local cache = world and world.manifold_cache
        local contacts = cache and cache.by_part and cache.by_part[part_id]
        if not contacts then
            return nil
        end
        max_ny = tonumber(max_ny) or 0.6
        dirx = tonumber(dirx) or 0
        dirz = tonumber(dirz) or 0
        local best_nx, best_nz, best_into
        for _, m in pairs(contacts) do
            if m.points and #m.points > 0 and (m.inactive_frames or 0) == 0 then
                -- manifold normal points a->b, orient it to point AT the part
                local nx = m.normal_x or 0
                local ny = m.normal_y or 0
                local nz = m.normal_z or 0
                if m.part_a_id == part_id then
                    nx, ny, nz = -nx, -ny, -nz
                end
                -- symmetric window: a ceiling graze (ny~-1) has noise-sized horizontal that would normalize into a phantom wall
                if ny < max_ny and ny > -max_ny then
                    local hlen = math.sqrt(nx * nx + nz * nz)
                    if hlen > 1e-6 then
                        nx, nz = nx / hlen, nz / hlen
                        local into = dirx * nx + dirz * nz
                        if into < -1e-6 and (best_into == nil or into < best_into) then
                            best_into = into
                            best_nx, best_nz = nx, nz
                        end
                    end
                end
            end
        end
        return best_nx, best_nz
    end

    function RBX:_physics_raycast(ox, oy, oz, dx, dy, dz, opts)
        opts = opts or {}
        local world = query_world_and_extras(self, opts)
        opts.collision_groups = world and world.collision_groups
        local hit = Queries.raycast(world, ox, oy, oz, dx, dy, dz, opts)
        -- cap so an undrawn frame cant leak the buffer
        if world and self._physics_debug_enabled and self:_physics_debug_enabled() then
            local rec = self._debug_raycasts or {}
            self._debug_raycasts = rec
            if #rec < DEBUG_RECORD_CAP then
                if hit then
                    rec[#rec + 1] = { ox = ox, oy = oy, oz = oz, hx = hit.px, hy = hit.py, hz = hit.pz, hit = true }
                else
                    rec[#rec + 1] = { ox = ox, oy = oy, oz = oz, hx = ox + dx, hy = oy + dy, hz = oz + dz, hit = false }
                end
            end
        end
        return hit
    end

    function RBX:_physics_region_parts(minx, miny, minz, maxx, maxy, maxz, opts, out)
        opts = opts or {}
        local world = query_world_and_extras(self, opts)
        if world and self._physics_debug_enabled and self:_physics_debug_enabled() then
            local rec = self._debug_regions or {}
            self._debug_regions = rec
            if #rec < DEBUG_RECORD_CAP then
                rec[#rec + 1] = { minx = minx, miny = miny, minz = minz, maxx = maxx, maxy = maxy, maxz = maxz }
            end
        end
        return Queries.region(world, minx, miny, minz, maxx, maxy, maxz, opts, out)
    end

    -- facade calls this on access, the per-step diff only considers listened parts
    function RBX:_register_touch_listener(part)
        if type(part) ~= "table" or not part._id then
            return
        end
        self._touch_listener_ids = self._touch_listener_ids or {}
        self._touch_listener_ids[part._id] = part
        self._touch_listener_revision = (self._touch_listener_revision or 0) + 1
    end

    function RBX:_refresh_runtime_part_mass(part)
        if type(part) ~= "table" then
            return 0
        end
        local view = plain_view(part)
        local mass = Materials.mass_of(view)
        Materials.box_inertia(view, mass) -- validate before publishing any mass fields
        part.Mass = mass
        -- singleton values, ensure_assemblies overwrites w/ real ones next rebuild
        part.AssemblyMass = mass
        part.AssemblyCenterOfMass = { x = view.Position.x, y = view.Position.y, z = view.Position.z }
        if part.AssemblyRootPart == nil then
            part.AssemblyRootPart = part
        end
        invalidate(deps, part, "Mass")
        invalidate(deps, part, "AssemblyMass")
        invalidate(deps, part, "AssemblyCenterOfMass")
        invalidate(deps, part, "AssemblyRootPart")
        -- topology decision. three tiers, cheapest first:
        --   1. UNBOUND part on a built world: no rebuild -- the registration that
        --      follows creation owns the decision (incremental singleton add or
        --      full rebuild). Pre-dirtying here would defeat that fast path for
        --      every runtime part creation
        --   2. BOUND clean SINGLETON with unchanged Anchored: in-place view +
        --      derived-cache refresh via _try_inplace_singleton_geometry_refresh
        --      (covers post-create Size/Shape/Material/Massless/
        --      CustomPhysicalProperties writes, which used to force a whole-world
        --      rebuild each -- or worse, never reach physics at all)
        --   3. anything else (welded member, anchored flip, unbuilt world): full
        --      rebuild, as before
        local world = self._physics_world
        local handled_in_place = false
        if world ~= nil and world.assemblies_built and part._id ~= nil
            and world.part_to_assembly ~= nil then
            if world.part_to_assembly[part._id] == nil then
                handled_in_place = true -- tier 1: registration decides later
            else
                handled_in_place = self:_try_inplace_singleton_geometry_refresh(world, part)
            end
        end
        if not handled_in_place then
            self._physics_assembly_dirty = true
            if world then
                world:mark_assembly_dirty()
            end
        end
        return mass
    end

    function RBX:_refresh_physics_part_registration(part)
        self._physics_dynamic_parts = self._physics_dynamic_parts or {}
        if type(part) ~= "table" or not part._id then
            return
        end
        -- mid-creation property descriptors defer to the creation epilogue's single
        -- registration with the complete property set (see _create_runtime_part)
        if part._physics_defer_registration then
            return
        end
        local world = ensure_world(self)
        if part._destroyed or part._workspace_active==false then
            self._physics_dynamic_parts[part._id] = nil
            return self:_on_runtime_part_removed_from_physics(part)
        end
        -- live collider again: clear exclusion so rebuild re-includes it
        part._physics_excluded = nil
        part._physics_remove_attempted = nil
        part._physics_remove_fallback = nil
        part._physics_removed_inplace = nil
        part._physics_destroy_rebuild_counted = nil
        if self.physics_enabled ~= true or part.Anchored == true then
            self._physics_dynamic_parts[part._id] = nil
        else
            self._physics_dynamic_parts[part._id] = part
            -- queries must see it before the next step upserts it
            self._physics_pending_query_parts = self._physics_pending_query_parts or {}
            self._physics_pending_query_parts[part._id] = part
            self._query_extras_epoch = (self._query_extras_epoch or 0) + 1
        end
        -- lone bound part flips in place, else full rebuild
        if self.physics_enabled == true and self:_try_inplace_anchored_flip(world, part) then
            return
        end
        -- brand-new dependency-free part while topology is clean: splice a singleton
        -- assembly in place. the fallback is mark_assembly_dirty -> whole-world
        -- ensure_assemblies, which allocates a plain_view for EVERY part -- a
        -- 200-800ms + ~180MB hitch at 48k parts, previously fired per NPC spawn
        if self.physics_enabled == true and self:_try_incremental_singleton_add(world, part) then
            return
        end
        world:mark_assembly_dirty()
        self._physics_assembly_dirty = true
    end

    -- a brand-new part with nothing referencing it can enter a clean world as its own
    -- assembly, every uncertain case returns false and keeps the topology rebuild
    function RBX:_try_incremental_singleton_add(world, part)
        if part._destroyed or part._id == nil then return false end
        if not (world and world.assemblies_built) or world.assembly_dirty then return false end
        if world.part_to_assembly and world.part_to_assembly[part._id] ~= nil then return false end
        -- conservative dependency guards: ANY joint/mover/follower in the world forces
        -- the rebuild path (resolving per-part references here would re-walk the very
        -- lists this fast path exists to avoid). Maps that ingest joints simply keep
        -- today's behavior
        local constraints = self._physics_constraints
        if constraints and #constraints > 0 then return false end
        local movers = self._physics_movers
        if movers and #movers > 0 then return false end
        local followers = self._physics_motor_followers
        if followers and #followers > 0 then return false end
        if self.physics_surface_welds == true then return false end

        local result = Assembly.build({ plain_view(part) }, nil)
        local asm = result.assemblies and result.assemblies[1]
        if not asm or #result.assemblies ~= 1 then return false end
        if not world:add_singleton_assembly(asm) then return false end

        -- same write-back + bind ensure_assemblies performs, scoped to one assembly
        part.AssemblyMass = asm.mass
        part.AssemblyCenterOfMass = { x = asm.com_x, y = asm.com_y, z = asm.com_z }
        part.AssemblyRootPart = asm.root_part and asm.root_part._part or nil
        invalidate(deps, part, "AssemblyMass")
        invalidate(deps, part, "AssemblyCenterOfMass")
        invalidate(deps, part, "AssemblyRootPart")
        local body = asm.body
        if body and not body.is_static then
            bind_one_assembly(asm)
            -- runtime parts always start awake (apply_activation_mode parity), keep the
            -- support pass from re-sleeping it if one runs later this rebuild epoch
            local forced = world._forced_awake
            if forced then forced[body] = true end
        end
        -- sleepers overlapping the new part's volume must re-evaluate (the old
        -- full-rebuild path re-ran support classification, give them the same nudge)
        if part.CanCollide ~= false then
            local wx0, wy0, wz0, wx1, wy1, wz1 = part_wake_box(part, 1)
            wake_sleepers_overlapping(world, wx0, wy0, wz0, wx1, wy1, wz1)
        end
        if self.collect_hotspot_stats == true then
            self._physics_incremental_singleton_add_count =
                (self._physics_incremental_singleton_add_count or 0) + 1
        end
        return true
    end

    -- Left the world (destroyed/reparented out). a dependency-free singleton can be
    -- detached in place, every uncertain case keeps the original topology rebuild
    function RBX:_on_runtime_part_removed_from_physics(part)
        if type(part) ~= "table" or part._id == nil then
            return false
        end
        local part_id = part._id
        if self._physics_dynamic_parts then
            self._physics_dynamic_parts[part_id] = nil
        end
        -- else _touch_listener_ids leaks dead ids and the zero-cost early-out never re-engages
        if self._touch_listener_ids then
            self._touch_listener_ids[part_id] = nil
        end

        -- DataModel:Destroy reparents first and then performs final core cleanup, so this
        -- hook can be called twice for one part. the first call owns the physics mutation;
        -- the second only attributes a pending fallback to destruction diagnostics
        if part._physics_remove_attempted then
            if part._destroyed and part._physics_remove_fallback
                and not part._physics_destroy_rebuild_counted then
                part._physics_destroy_rebuild_counted = true
                if self.collect_hotspot_stats == true then
                    self._physics_destroy_full_rebuild_count =
                        (self._physics_destroy_full_rebuild_count or 0) + 1
                end
            end
            return part._physics_removed_inplace == true
        end
        part._physics_remove_attempted = true
        part._physics_excluded = true
        self._query_extras_epoch = (self._query_extras_epoch or 0) + 1
        if self._physics_pending_query_parts then
            self._physics_pending_query_parts[part_id] = nil
        end

        local world = self._physics_world
        local fast_guard = "world_unavailable"
        if world and world.assemblies_built and not world.assembly_dirty then
            local asm = world.part_to_assembly and world.part_to_assembly[part_id]
            local body = asm and asm.body
            local members = asm and asm.parts
            if not asm and (part._workspace_active == false or part._destroyed) then
                -- the membership transition already made this part inactive and
                -- the clean current topology has no body for it. Query/dynamic
                -- bookkeeping was cleared above, rebuilding every other body
                -- cannot remove a physics object that is already absent
                part._physics_removed_inplace = true
                if self.collect_hotspot_stats == true then
                    self._physics_incremental_unbound_remove_count =
                        (self._physics_incremental_unbound_remove_count or 0) + 1
                end
                return true
            elseif not asm then
                fast_guard = "missing_assembly"
            elseif not members or #members ~= 1 then
                fast_guard = "not_singleton"
            elseif singleton_removal_has_dependency(self, world, part, body) then
                fast_guard = "runtime_dependency"
            else
                local wx0, wy0, wz0, wx1, wy1, wz1 = part_wake_box(part, 1)
                local removed, reason = world:remove_singleton_assembly(part_id)
                if removed then
                    if self._physics_woken_part_ids then self._physics_woken_part_ids[part_id] = nil end
                    if self._physics_explicitly_activated_part_ids then
                        self._physics_explicitly_activated_part_ids[part_id] = nil
                    end
                    if self._physics_movers_by_part_id then self._physics_movers_by_part_id[part_id] = nil end
                    if self._physics_rotate_followers_by_part_id then
                        self._physics_rotate_followers_by_part_id[part_id] = nil
                    end
                    if self._physics_follower_rest_cache then
                        self._physics_follower_rest_cache[part_id] = nil
                    end
                    if self._physics_part_assembly_by_id then
                        self._physics_part_assembly_by_id[part_id] = nil
                    end
                    -- non-collidable markers never support a sleeper, avoid waking nearby
                    -- bodies for those common destruction events
                    if part.CanCollide ~= false then
                        wake_sleepers_overlapping(world, wx0, wy0, wz0, wx1, wy1, wz1)
                    end
                    part._physics_removed_inplace = true
                    if self.collect_hotspot_stats == true then
                        self._physics_incremental_singleton_remove_count =
                            (self._physics_incremental_singleton_remove_count or 0) + 1
                    end
                    return true
                end
                fast_guard = reason or "world_guard"
            end
        elseif world and world.assembly_dirty then
            fast_guard = "topology_dirty"
        elseif world and not world.assemblies_built then
            fast_guard = "world_not_built"
        end

        part._physics_remove_fallback = true
        self._physics_assembly_dirty = true
        if world then world:mark_assembly_dirty() end
        if self.collect_hotspot_stats == true then
            self._physics_incremental_singleton_remove_fallback_count =
                (self._physics_incremental_singleton_remove_fallback_count or 0) + 1
            self._physics_incremental_singleton_remove_last_guard = fast_guard
            if part._destroyed and not part._physics_destroy_rebuild_counted then
                part._physics_destroy_rebuild_counted = true
                self._physics_destroy_full_rebuild_count =
                    (self._physics_destroy_full_rebuild_count or 0) + 1
            end
        end
        return false
    end

    function RBX:_ingest_parsed_physics_instances(parsed_physics_instances)
        self._parsed_physics_instances =
            type(parsed_physics_instances) == "table" and parsed_physics_instances or {}
        self._physics_constraints = {}
        self._physics_movers = {}
        self._physics_movers_by_part_id = {}
        self._physics_motor_followers = {}
        self._physics_no_collision_constraints = {}
        -- re-arm the one-time unsupported-joint warning
        self._physics_unsupported_joint_warned = false
        local world = ensure_world(self)
        -- new map: drop no-collision sets, rebuilt next rebuild
        world.no_collision = {}
        world.no_collision_runtime = {}
        -- physics_anchor_loaded_parts: every map part is forced static, so authored joints
        -- (Weld/Snap fuse unanchored parts into assemblies) and movers (forces on dynamics)
        -- are inert -- skip them. on 20k+-joint maps this keeps EVERY later assembly rebuild
        -- (fires on runtime part add/remove) from re-resolving the whole joint list
        local skip_map_joints = self.physics_anchor_loaded_parts
        for index = 1, #self._parsed_physics_instances do
            local source = self._parsed_physics_instances[index]
            if type(source) == "table" then
                if source.kind == "mover" then
                    if not skip_map_joints then
                        self._physics_movers[#self._physics_movers + 1] = source
                    end
                elseif source.kind == "no_collision" or source.class_name == "NoCollisionConstraint" then
                    self._physics_no_collision_constraints[#self._physics_no_collision_constraints + 1] = source
                elseif not skip_map_joints then
                    self._physics_constraints[#self._physics_constraints + 1] = source
                end
            end
        end
        world:mark_assembly_dirty()
        self._physics_assembly_dirty = true
    end

    function RBX:_rebuild_physics_assemblies()
        local world = ensure_world(self)
        world:mark_assembly_dirty()
        return ensure_assemblies(self)
    end

    -- rigid-joint lifecycle (disable / break / add / motor transform)

    -- disabling drops the fusion edge (assembly splits next rebuild)
    function RBX:_set_physics_joint_enabled(selector, enabled)
        local joint = find_constraint(self, selector)
        if not joint then
            return false
        end
        joint.enabled = enabled ~= false
        mark_joint_topology_dirty(self)
        return true
    end

    -- splits the assembly, newly-freed unanchored pieces wake
    function RBX:_remove_physics_joint(selector)
        local joint, index = find_constraint(self, selector)
        if not joint or not index then
            return false
        end
        table.remove(self._physics_constraints, index)
        mark_joint_topology_dirty(self)
        return true
    end

    -- stores direct part refs (no referent plumbing). opts: { name, enabled, class_name, c0, c1 }
    function RBX:_add_physics_joint(class_name, part0, part1, opts)
        opts = opts or {}
        self._physics_constraints = self._physics_constraints or {}
        local cls = class_name or "Weld"
        local joint = {
            kind = "joint",
            class_name = cls,
            name = opts.name or cls,
            enabled = opts.enabled ~= false,
            part0_referent = referent_of_part(part0),
            part1_referent = referent_of_part(part1),
            _part0 = part0,
            _part1 = part1,
            c0 = opts.c0,
            c1 = opts.c1,
        }
        self._physics_constraints[#self._physics_constraints + 1] = joint
        mark_joint_topology_dirty(self)
        return joint
    end

    -- datamodel destroy/unparent hook, takes any find_constraint selector
    function RBX:_on_physics_joint_destroyed(selector)
        return self:_remove_physics_joint(selector)
    end

    -- non-identity transform makes part1 a kinematic follower instead of rigid-fused
    function RBX:_set_motor6d_transform(selector, transform)
        local joint = find_constraint(self, selector)
        if not joint then
            return false
        end
        local flat = to_flat_cframe(transform)
        joint._transform = flat
        joint._kinematic = not CFrameMath.is_identity(flat)
        mark_joint_topology_dirty(self)
        return true
    end

    -- movers act on assemblies, dont fuse topology, bypass rebuild
    function RBX:_add_physics_mover(spec)
        if type(spec) ~= "table" then
            return nil
        end
        local world = ensure_world(self)
        local rec = {}
        for k, v in pairs(spec) do
            rec[k] = v
        end
        if rec.part_id == nil then
            local part = spec.part or spec.Part or spec._part
            rec.part_id = type(part) == "table" and part._id or nil
        end
        if rec.part_id == nil then
            return nil
        end
        rec.part, rec.Part, rec._part = nil, nil, nil   -- keep the engine record host-agnostic
        return world.movers:add(rec)
    end

    function RBX:_remove_physics_mover(id)
        local world = self._physics_world
        if not world or not world.movers then
            return false
        end
        return world.movers:remove(id)
    end

    function RBX:_set_physics_mover_enabled(id, enabled)
        local world = self._physics_world
        if not world or not world.movers then
            return false
        end
        return world.movers:set_enabled(id, enabled)
    end

    -- part_id nil = remove. own id namespace so the per-step parsed re-sync never drops it
    function RBX:_sync_runtime_body_mover(id, class_name, props, part_id)
        local world = ensure_world(self)
        if not world or not world.movers then
            return false
        end
        if part_id == nil then
            world.movers:remove(id)
            return false
        end
        -- fast path: controller rewrites Force/CFrame every frame -> mutate in place
        local existing = world.movers:get(id)
        if existing ~= nil and type(props) == "table" then
            if class_name == "BodyGyro" and props.goal_quat == nil then
                local qw, qx, qy, qz = cframe_goal_quat(props.cframe)
                local goal = existing.goal_quat
                if type(goal) ~= "table" then
                    goal = {}
                end
                goal.qw, goal.qx, goal.qy, goal.qz = qw, qx, qy, qz
                props.goal_quat = goal
            end
            if Movers.update_legacy(existing, class_name, props, part_id) then
                local asm = world.part_to_assembly and world.part_to_assembly[part_id]
                local body = asm and asm.body
                if body and not body.is_static and body.sleeping and body.wake then
                    wake_body_fast(body)
                end
                return true
            end
        end
        local src = { class_name = class_name, enabled = true }
        if type(props) == "table" then
            for k, v in pairs(props) do src[k] = v end
        end
        -- from_legacy wants a goal quat, bodygyro carries a CFrame
        if class_name == "BodyGyro" and src.goal_quat == nil then
            local qw, qx, qy, qz = cframe_goal_quat(src.cframe)
            src.goal_quat = { qw = qw, qx = qx, qy = qy, qz = qz }
        end
        local rec = Movers.from_legacy(src, part_id, id)
        if not rec then
            world.movers:remove(id)
            return false
        end
        world.movers:add(rec)
        -- else a fresh force does nothing until something nudges it
        local asm = world.part_to_assembly and world.part_to_assembly[part_id]
        local body = asm and asm.body
        if body and not body.is_static and body.sleeping and body.wake then
            wake_body_fast(body)
        end
        return true
    end

    function RBX:_remove_runtime_body_mover(id)
        local world = self._physics_world
        if not world or not world.movers then
            return false
        end
        return world.movers:remove(id)
    end

    function RBX:_is_runtime_part_physics_anchored(part)
        if type(part) ~= "table" or part.Anchored == true then
            return true
        end
        local world = ensure_assemblies(self)
        local assembly = part._id ~= nil and world.part_to_assembly[part._id] or nil
        return assembly ~= nil and assembly.anchored == true or false
    end

    -- an anchored part's velocity is a contact-surface velocity. its transform
    -- stays fixed, so starting a belt would otherwise leave its cargo asleep
    -- Query only neighboring hash cells, and collect before waking: wake_body
    -- moves proxies between hashes and must not mutate a bucket being visited
    local function wake_surface_contacts(self, part)
        local world = self._physics_world
        local bp = world and world.broadphase
        local asm = world and world.part_to_assembly[part._id]
        if not bp or not asm or not asm.body or not asm.body.is_static or part.CanCollide == false then return end
        local lx, ly, lz, rx, ry, rz = Queries.part_world_aabb(part)
        local margin = .05 -- contact slop plus the outward broadphase padding
        lx, ly, lz = lx - margin, ly - margin, lz - margin
        rx, ry, rz = rx + margin, ry + margin, rz + margin
        local targets = self._surface_wake_targets or {}
        self._surface_wake_targets = targets
        local count = 0
        bp:collect_region(lx, ly, lz, rx, ry, rz, function(body)
            local proxy = body.sleeping and bp.sleeping_proxies[body.id]
            local a = proxy and proxy.aabb
            if a and a[4] >= lx and a[1] <= rx and a[5] >= ly and a[2] <= ry
                and a[6] >= lz and a[3] <= rz then
                count = count + 1
                targets[count] = body
            end
        end)
        for i = 1, count do
            world:wake_body(targets[i])
            targets[i] = nil
        end
    end

    function RBX:_set_runtime_part_assembly_linear_velocity(part, value)
        if type(part) ~= "table" or part._destroyed then
            return
        end
        local vx, vy, vz = to_vec3(value, 0, 0, 0)
        local oldx, oldy, oldz = to_vec3(part.AssemblyLinearVelocity or part.Velocity, 0, 0, 0)
        local wx, wy, wz = to_vec3(part.AssemblyAngularVelocity or part.RotVelocity, 0, 0, 0)
        write_velocity_aliases(deps, part, vx, vy, vz, wx, wy, wz)
        local body = dynamic_body_for_part(self, part)
        if body then
            body._velocity_publication_dirty=true
            -- zero written to a SLEEPING body must not wake it (its velocity is already
            -- zero): parked far-tier NPCs would otherwise unpark on every AI zero-write,
            -- each one an O(all-bodies) refresh. any nonzero write still wakes, O(1)
            if body.sleeping and vx == 0 and vy == 0 and vz == 0 then
                return
            end
            body.vx, body.vy, body.vz = vx, vy, vz
            wake_body_fast(body)
        elseif vx ~= oldx or vy ~= oldy or vz ~= oldz then
            wake_surface_contacts(self, part)
        end
        -- so activation-mode rebuilds keep it awake
        if vx ~= 0 or vy ~= 0 or vz ~= 0 then
            track_woken(self, part)
        end
    end

    function RBX:_set_runtime_part_assembly_angular_velocity(part, value)
        if type(part) ~= "table" or part._destroyed then
            return
        end
        local wx, wy, wz = to_vec3(value, 0, 0, 0)
        local oldx, oldy, oldz = to_vec3(part.AssemblyAngularVelocity or part.RotVelocity, 0, 0, 0)
        local vx, vy, vz = to_vec3(part.AssemblyLinearVelocity or part.Velocity, 0, 0, 0)
        write_velocity_aliases(deps, part, vx, vy, vz, wx, wy, wz)
        local body = dynamic_body_for_part(self, part)
        if body then
            body._velocity_publication_dirty=true
            -- same zero-write-stays-asleep rule as the linear setter above
            if body.sleeping and wx == 0 and wy == 0 and wz == 0 then
                return
            end
            -- rotation-locked bodies must never accumulate angular velocity: the
            -- integrator would rotate the quat straight from wx/wy/wz and the
            -- identity-orientation invariant (cheap axis-aligned collider path)
            -- would be silently lost
            if body.rotation_locked then
                body.wx, body.wy, body.wz = 0, 0, 0
            else
                body.wx, body.wy, body.wz = wx, wy, wz
            end
            wake_body_fast(body)
        elseif wx ~= oldx or wy ~= oldy or wz ~= oldz then
            wake_surface_contacts(self, part)
        end
        if wx ~= 0 or wy ~= 0 or wz ~= 0 then
            track_woken(self, part)
        end
    end

    function RBX:_apply_runtime_part_impulse(part, impulse)
        ensure_assemblies(self)
        local body = dynamic_body_for_part(self, part)
        if not body then
            return
        end
        -- pre-wake O(1) so the internal Body:wake sees an awake body (no refresh_active);
        -- matters when the target is a parked/slept NPC hit by a punt or weapon
        if body.sleeping then wake_body_fast(body) end
        local ix, iy, iz = to_vec3(impulse, 0, 0, 0)
        body:apply_impulse(ix, iy, iz)
        publish_impulse_velocity(deps, body)
        track_woken(self, part)
    end

    function RBX:_apply_runtime_part_impulse_at_position(part, impulse, position)
        ensure_assemblies(self)
        local body = dynamic_body_for_part(self, part)
        if not body then
            return
        end
        if body.sleeping then wake_body_fast(body) end
        local ix, iy, iz = to_vec3(impulse, 0, 0, 0)
        local px, py, pz = to_vec3(position, body.com_x, body.com_y, body.com_z)
        body:apply_impulse_at(ix, iy, iz, px, py, pz)
        publish_impulse_velocity(deps, body)
        track_woken(self, part)
    end

    function RBX:_apply_runtime_part_angular_impulse(part, impulse)
        ensure_assemblies(self)
        local body = dynamic_body_for_part(self, part)
        if not body then
            return
        end
        if body.sleeping then wake_body_fast(body) end
        local ix, iy, iz = to_vec3(impulse, 0, 0, 0)
        body:apply_angular_impulse(ix, iy, iz)
        publish_impulse_velocity(deps, body)
        track_woken(self, part)
    end

    -- one exact pair, stored in persistent + effective sets so it survives rebuilds
    function RBX:_set_runtime_parts_no_collision(part_a, part_b, enabled)
        local world = ensure_world(self)
        if type(part_a) ~= "table" or type(part_b) ~= "table" then
            return
        end
        local a, b = part_a._id, part_b._id
        if a == nil or b == nil then
            return
        end
        local key = no_collision_key(a, b)
        world.no_collision_runtime = world.no_collision_runtime or {}
        local had = world.no_collision[key] == true
        if enabled == false then
            world.no_collision_runtime[key] = nil
            world.no_collision[key] = nil
        else
            world.no_collision_runtime[key] = true
            world.no_collision[key] = true
        end
        if (world.no_collision[key] == true) ~= had then
            world.collision_dirty = true
            if world.manifold_cache then
                world.manifold_cache:remove_pair(contact_pair_key(a, b))
            end
            note_filter_clear(world)
        end
    end

    -- collision-group matrix api

    function RBX:_get_collision_group_registry()
        return ensure_world(self).collision_groups
    end

    function RBX:_register_collision_group(name, id)
        return self:_get_collision_group_registry():register(name, id)
    end

    -- clears the WHOLE contact cache: a matrix change can affect many pairs
    function RBX:_set_collision_groups_collidable(group_a, group_b, collidable)
        local world = ensure_world(self)
        local changed = world.collision_groups:set_collidable(group_a, group_b, collidable)
        if changed then
            world.collision_dirty = true
            if world.manifold_cache then
                world.manifold_cache:clear()
            end
            note_filter_clear(world)
        end
        return changed
    end

    function RBX:_collision_groups_collidable(group_a, group_b)
        local world = ensure_world(self)
        return world.collision_groups:collidable(group_a, group_b)
    end

    -- drops its cached contacts (filter change)
    function RBX:_set_runtime_part_collision_group(part, group)
        if type(part) ~= "table" then
            return
        end
        return RBX._collision_group_part.set_name(self, part, group, function(target, key)
            invalidate(deps, target, key)
        end)
    end

    -- Rotation lock (NPC boxes): zero inverse inertia so the body never rotates -- an
    -- unrotated spawn keeps an identity quat forever, staying on the aa narrowphase
    -- clip path and the tight broadphase box. Persisted on the part so rebuilds
    -- re-derive it (plain_view -> Assembly.build), mirrored onto the bound root view
    -- so recompute_mass keeps it. Locking does NOT snap an already-drifted quat
    function RBX:_set_runtime_part_rotation_locked(part, locked)
        if type(part) ~= "table" or part._destroyed then
            return
        end
        locked = locked == true
        part.RotationLocked = locked
        local world = self._physics_world
        local asm = world and world.part_to_assembly and world.part_to_assembly[part._id]
        if asm then
            local root = asm.root_part
            if root then
                root.RotationLocked = locked
            end
            local body = asm.body
            if body and not body.is_static and body.set_rotation_locked then
                body:set_rotation_locked(locked)
            end
        end
    end

    -- park-to-sleep tier (far NPCs): immediate O(1) external sleep. the body keeps a
    -- rest-pose sleeping proxy -- awake bodies still collide with it, raycasts still
    -- hit it, impact-wake and support-release wake still fire -- but it costs zero
    -- per-substep work. caller contract: only park GROUNDED bodies, call from game
    -- update. Idempotent (false = not parked / already parked)
    function RBX:_park_runtime_part(part)
        local body = dynamic_body_for_part(self, part)
        if not body or body.sleeping then
            return false
        end
        local world = body.world
        if not world then
            return false
        end
        world:park_body(body)
        -- game-visible velocity reads must agree with the zeroed body
        write_velocity_aliases(deps, part, 0, 0, 0, 0, 0, 0)
        return true
    end

    function RBX:_unpark_runtime_part(part)
        local body = dynamic_body_for_part(self, part)
        if not body or not body.sleeping then
            return false
        end
        local world = body.world
        if not world then
            return false
        end
        world:unpark_body(body)
        return true
    end

    function RBX:wake_parts_in_bounds(minimum, maximum, collision_group)
        local world=self._physics_world
        if not world then return 0 end
        local x0,y0,z0=minimum.x,minimum.y,minimum.z
        local x1,y1,z1=maximum.x,maximum.y,maximum.z
        assert(x1>=x0 and y1>=y0 and z1>=z0 and x1-x0<=64 and y1-y0<=64 and z1-z0<=64,
            "wake bounds must be a local volume no larger than 64 studs per axis")
        return world:wake_in_bounds(x0,y0,z0,x1,y1,z1,collision_group)
    end

    -- nocollisionconstraint lifecycle

    -- no topology rebuild
    function RBX:_refresh_no_collision()
        local world = self._physics_world
        if world then
            rebuild_no_collision(self, world)
        end
        return world
    end

    -- opts: { name, enabled, referent }
    function RBX:_add_no_collision_constraint(part0, part1, opts)
        opts = opts or {}
        self._physics_no_collision_constraints = self._physics_no_collision_constraints or {}
        local c = {
            kind = "no_collision",
            class_name = "NoCollisionConstraint",
            name = opts.name or "NoCollisionConstraint",
            enabled = opts.enabled ~= false,
            part0_referent = referent_of_part(part0),
            part1_referent = referent_of_part(part1),
            _part0 = part0,
            _part1 = part1,
            referent = opts.referent,
        }
        self._physics_no_collision_constraints[#self._physics_no_collision_constraints + 1] = c
        local world = ensure_world(self)
        rebuild_no_collision(self, world)
        if c.enabled and type(part0) == "table" and type(part1) == "table"
            and part0._id ~= nil and part1._id ~= nil and world.manifold_cache then
            world.manifold_cache:remove_pair(contact_pair_key(part0._id, part1._id))
        end
        note_filter_clear(world)
        return c
    end

    function RBX:_set_no_collision_constraint_enabled(selector, enabled)
        local c = find_no_collision_constraint(self, selector)
        if not c then
            return false
        end
        c.enabled = enabled ~= false
        local world = ensure_world(self)
        rebuild_no_collision(self, world)
        local pa = c._part0 or (self._runtime_part_by_referent or {})[c.part0_referent]
        local pb = c._part1 or (self._runtime_part_by_referent or {})[c.part1_referent]
        if pa and pb and pa._id ~= nil and pb._id ~= nil and world.manifold_cache then
            world.manifold_cache:remove_pair(contact_pair_key(pa._id, pb._id))
        end
        note_filter_clear(world)
        return true
    end

    function RBX:_remove_no_collision_constraint(selector)
        local c, index = find_no_collision_constraint(self, selector)
        if not c or not index then
            return false
        end
        table.remove(self._physics_no_collision_constraints, index)
        local world = ensure_world(self)
        rebuild_no_collision(self, world)
        note_filter_clear(world)
        return true
    end

    -- datamodel destroy hook
    function RBX:_on_no_collision_constraint_destroyed(selector)
        return self:_remove_no_collision_constraint(selector)
    end

    -- a rigid pose change preserves bound dynamic topology, including welded
    -- members. Structural edits and kinematic/static bodies retain the rebuild path
    local function try_inplace_part_teleport(self, world, part)
        if world.assembly_dirty then
            return false -- rebuild pending, it binds the new pose
        end
        local asm = world.part_to_assembly and world.part_to_assembly[part._id]
        local body = asm and asm.body
        if not body or body.is_static or body.kinematic then
            return false
        end
        local members = asm.parts
        local offsets = body.local_offsets
        if not members or not offsets or #members == 0 or #offsets ~= #members then
            return false
        end
        local member_offset
        for i = 1, #offsets do
            local offset = offsets[i]
            local member = offset.view and offset.view._part
            if not member or member._destroyed then return false end
            if member == part then member_offset = offset end
        end
        if not member_offset then return false end
        local cf = part.CFrame
        if type(cf) ~= "table" then
            return false
        end
        local x = tonumber(cf.x) or 0
        local y = tonumber(cf.y) or 0
        local z = tonumber(cf.z) or 0
        -- Sleepers resting on ANY member's old pose lose their support
        -- read the bound pose: the addressed part already contains its new CFrame
        for i = 1, #offsets do
            local offset = offsets[i]
            local dx, dy, dz = Integrate.rotate_vec(body.qw, body.qx, body.qy, body.qz,
                offset.lx, offset.ly, offset.lz)
            local ox, oy, oz = body.com_x + dx, body.com_y + dy, body.com_z + dz
            local size = offset.view._part.Size
            local sx, sy, sz = size.x or 1, size.y or 1, size.z or 1
            local radius = math.sqrt(sx * sx + sy * sy + sz * sz) * 0.5 + 1
            -- wake neighbors here, publish this body only after its new COM is installed
            wake_sleepers_overlapping(world, ox - radius, oy - radius, oz - radius,
                ox + radius, oy + radius, oz + radius, body.id)
        end
        local qw, qx, qy, qz = Integrate.quat_from_matrix(
            cf.r00 or 1, cf.r01 or 0, cf.r02 or 0,
            cf.r10 or 0, cf.r11 or 1, cf.r12 or 0,
            cf.r20 or 0, cf.r21 or 0, cf.r22 or 1)
        local off = member_offset
        local iw, ix, iy, iz = Integrate.quat_conj(off.qw, off.qx, off.qy, off.qz)
        qw, qx, qy, qz = Integrate.quat_mul(qw, qx, qy, qz, iw, ix, iy, iz)
        qw, qx, qy, qz = Integrate.quat_normalize(qw, qx, qy, qz)
        local dx, dy, dz = Integrate.rotate_vec(qw, qx, qy, qz, off.lx, off.ly, off.lz)
        x, y, z = x - dx, y - dy, z - dz
        body.com_x, body.com_y, body.com_z = x, y, z
        body.qw, body.qx, body.qy, body.qz = qw, qx, qy, qz
        body:update_world_inertia()
        asm.com_x, asm.com_y, asm.com_z = x, y, z
        -- contacts at the old pose are meaningless (incl. warm-start impulses)
        if world.manifold_cache then
            for i = 1, #offsets do
                world.manifold_cache:remove_for_part(offsets[i].view._part._id)
            end
            note_filter_clear(world)
        end
        if body.sleeping then
            world:wake_body(body)
        else
            -- else deep-sleep latches a pre-teleport reference pose
            body.deep_timer = 0
            body.deep_ref_x = nil
        end
        -- publish the complete rigid pose without re-entering facade/Weld setters
        -- Queries must see every member before the next substep re-upserts
        if #members > 1 then write_back_body(self, world, deps, body) end
        self._physics_pending_query_parts = self._physics_pending_query_parts or {}
        for i = 1, #offsets do
            local view = offsets[i].view
            local member = view._part
            member.AssemblyCenterOfMass = { x = x, y = y, z = z }
            invalidate(deps, member, "AssemblyCenterOfMass")
            view.CFrameRef = member.CFrame
            view.Position.x, view.Position.y, view.Position.z = member.CFrame.x, member.CFrame.y, member.CFrame.z
            self._physics_pending_query_parts[member._id] = member
            -- loaded parts are left to the support bind pass, else they'd never re-sleep
            if member._loaded_from_map ~= true then track_woken(self, member) end
        end
        self._query_extras_epoch = (self._query_extras_epoch or 0) + 1
        return true
    end

    -- static broadphase insert + recompute_mass read from this view
    local function refresh_single_view(view, part)
        local cf = part.CFrame
        view.CFrameRef = cf
        local p = view.Position
        p.x = cf and (cf.x or 0) or 0
        p.y = cf and (cf.y or 0) or 0
        p.z = cf and (cf.z or 0) or 0
        view.Anchored = part.Anchored
        view.CanCollide = part.CanCollide
        view.CollisionGroup = part.CollisionGroup
        view.RotationLocked = part.RotationLocked
    end

    -- a rigid pose edit cannot change an anchored singleton's assembly graph
    -- refresh only its spatial/query representation and affected contacts;
    -- compound/kinematic bodies retain the established rebuild path
    local function try_inplace_static_singleton_pose(self, world, part)
        -- Opt-in legacy surface joints are inferred from spatial adjacency;
        -- changing a pose can change that graph even for a current singleton
        if self.physics_surface_welds == true then return false end
        if not world or not world.assemblies_built or world.assembly_dirty
            or part.Anchored ~= true then
            return false
        end
        local asm = world.part_to_assembly and world.part_to_assembly[part._id]
        local body = asm and asm.body
        local members = asm and asm.parts
        local view = members and #members == 1 and members[1]
        if not body or not body.is_static or body.kinematic
            or not view or view._part ~= part then
            return false
        end
        local collidable = part.CanCollide ~= false
        local bp = world.broadphase
        if collidable and bp then
            -- the facade contains the new pose, but the bound view still
            -- contains the old one. its bounds remain valid even if the
            -- static index is dirty or was disabled during an earlier edit
            local x0, y0, z0, x1, y1, z1 = bp:body_aabb(body)
            wake_sleepers_overlapping(world, x0-1, y0-1, z0-1, x1+1, y1+1, z1+1)
        end
        Continuous.record_static(world, body, view, part.CFrame)
        refresh_single_view(view, part)
        local position = view.Position
        local x, y, z = position.x, position.y, position.z
        local mass = asm.mass
        if mass and mass > 0 then
            -- match Assembly's singleton COM arithmetic without recomputing
            -- unchanged material mass, inertia and inverse mass properties
            x, y, z = (0 + x * mass) / mass,
                (0 + y * mass) / mass, (0 + z * mass) / mass
        end
        asm.com_x, asm.com_y, asm.com_z = x, y, z
        body.com_x, body.com_y, body.com_z = x, y, z
        body._static_member_cache = nil
        body._static_member_grid = nil
        body._query_member_grid = nil
        if world.manifold_cache then
            world.manifold_cache:remove_for_part(part._id)
        end
        if bp and world.config.collision_enabled and not world.broadphase_statics_dirty then
            if not (bp.refresh_static_singleton and bp:refresh_static_singleton(asm)) then
                bp:remove_static(asm.id)
                bp:insert_static(asm)
            end
            world.static_proxy_count = bp.static_proxy_count
        else
            -- a later query/step must rebuild stale proxies, including after
            -- collision is re-enabled. do not leave an old clean index behind
            world.broadphase_statics_dirty = true
        end
        part.AssemblyCenterOfMass = { x = x, y = y, z = z }
        invalidate(deps, part, "AssemblyCenterOfMass")
        if collidable and bp then
            local x0, y0, z0, x1, y1, z1 = bp:body_aabb(body)
            wake_sleepers_overlapping(world, x0-1, y0-1, z0-1, x1+1, y1+1, z1+1)
        end
        self._physics_inplace_static_pose_count = (self._physics_inplace_static_pose_count or 0) + 1
        return true
    end

    -- non-pose property change (Size/Shape/Material/Massless/CustomPhysicalProperties)
    -- on a bound clean SINGLETON: refresh the bind-time view snapshot + every cache
    -- derived from it, in place. returns true when handled, false = caller keeps the
    -- topology-rebuild path. without this, such writes either forced the whole-world
    -- rebuild (Size) or silently never reached physics at all (Shape/Material) once the
    -- incremental add/remove paths eliminated the accidental rebuilds that used to
    -- refresh views as a side effect
    function RBX:_try_inplace_singleton_geometry_refresh(world, part)
        if not world or not world.assemblies_built or world.assembly_dirty then
            return false
        end
        local asm = world.part_to_assembly and world.part_to_assembly[part._id]
        local body = asm and asm.body
        if not body or body.kinematic then
            return false
        end
        local members = asm.parts
        if not members or #members ~= 1 then
            return false
        end
        local view = members[1]
        if not view or view._part ~= part then
            return false
        end
        if (part.Anchored == true) ~= (body.is_static == true) then
            return false -- pending anchored flip, the flip path owns that transition
        end
        refresh_single_view(view, part)
        view.Size = part.Size
        view.Shape = part.Shape
        view.Massless = part.Massless
        view.CustomPhysicalProperties = part.CustomPhysicalProperties
        view.Material = part.Material
        -- narrowphase collider fields (kind/half-extents/friction/elasticity) are
        -- cached on the view "immutable per view lifetime" -- that lifetime just ended
        view._nc_cached = nil
        -- the broadphase com-sphere radius caches on local_offsets identity, which
        -- this in-place path deliberately does NOT rebuild -- drop it explicitly or
        -- a Size GROW leaves the dynamic hash/proxy.aabb undersized (missed pairs,
        -- missed rays, unwoken sleepers in the grown region)
        body._bp_radius = nil
        body._bp_radius_key = nil
        -- the tight identity-orient box caches on the same key, same staleness hazard
        body._bp_tight_key = nil
        Assembly.recompute_mass(asm)
        -- caches keyed to the previous geometry of this body are wrong
        body._static_member_cache = nil
        body._static_member_grid = nil
        body._query_member_grid = nil
        -- contacts (incl. warm-start impulses) against the old geometry are invalid
        if world.manifold_cache then
            world.manifold_cache:remove_for_part(part._id)
            note_filter_clear(world)
        end
        world.collision_dirty = true
        local bp = world.broadphase
        if bp then
            if body.is_static then
                -- static extents may have changed: refresh the broadphase proxy
                if world.config.collision_enabled and not world.broadphase_statics_dirty then
                    bp:remove_static(asm.id)
                    bp:insert_static(asm)
                    world.static_proxy_count = bp.static_proxy_count
                end
            elseif body.sleeping then
                -- a resized sleeper may now intersect (or stop supporting) neighbors
                world:wake_body(body)
            end
        end
        -- neighbors resting on the old extents must re-settle
        local wx0, wy0, wz0, wx1, wy1, wz1 = part_wake_box(part, 1)
        wake_sleepers_overlapping(world, wx0, wy0, wz0, wx1, wy1, wz1)
        part.AssemblyMass = asm.mass
        part.AssemblyCenterOfMass = { x = asm.com_x, y = asm.com_y, z = asm.com_z }
        return true
    end

    -- flip static<->dynamic where it stands, skips the whole-world rebuild. falls back to a dirty mark when unusual
    function RBX:_try_inplace_anchored_flip(world, part)
        if world.assembly_dirty then
            return false -- rebuild pending anyway, it handles the flip
        end
        local asm = world.part_to_assembly and world.part_to_assembly[part._id]
        local body = asm and asm.body
        if not body or body.kinematic then
            return false
        end
        local members = asm.parts
        if not members or #members ~= 1 then
            return false
        end
        local view = members[1]
        if not view or view._part ~= part then
            return false
        end
        local anchored = part.Anchored == true
        if body.is_static == anchored then
            return true -- redundant refresh, nothing to flip
        end
        local bp = world.broadphase
        if not bp then
            return false
        end
        refresh_single_view(view, part)
        if anchored then
            -- dynamic -> static: freeze at the current pose
            if body.sleeping then
                bp:remove_sleeping(body.id)
                world.sleeping_proxy_count = bp.sleeping_proxy_count or 0
                body.sleeping = false
            end
            bp:remove_dynamic(body.id)
            world:remove_active(body)
            body.vx, body.vy, body.vz = 0, 0, 0
            body.wx, body.wy, body.wz = 0, 0, 0
            Assembly.recompute_mass(asm)
            bp:insert_static(asm)
            self._physics_dynamic_parts = self._physics_dynamic_parts or {}
            self._physics_dynamic_parts[part._id] = nil
        else
            -- static -> dynamic: statics never got orientation/offsets bound, seed like bind_assembly_poses
            bp:remove_static(asm.id)
            Assembly.recompute_mass(asm)
            body.qw, body.qx, body.qy, body.qz = view_orientation(view)
            body:update_world_inertia()
            local offsets = body.local_offsets
            if not offsets then
                offsets = {}
                body.local_offsets = offsets
            end
            local off = offsets[1]
            if not off then
                off = {}
                offsets[1] = off
            end
            off.view = view
            off.lx, off.ly, off.lz = 0, 0, 0
            off.qw, off.qx, off.qy, off.qz = 1, 0, 0, 0
            for k = 2, #offsets do offsets[k] = nil end
            -- the classic `p.Velocity=v, p.Anchored=false` launch pattern
            local svx, svy, svz, swx, swy, swz = read_part_velocity(part)
            body.vx, body.vy, body.vz = svx, svy, svz
            body.wx, body.wy, body.wz = swx, swy, swz
            body.sleeping = false
            body.sleep_timer = 0
            body.deep_timer = 0
            body.deep_ref_x = nil
            body.deep_slept = false
            world:add_active(body)
            if part._loaded_from_map ~= true then
                track_woken(self, part)
            end
            -- sleepers on this released support must fall too, impact-wake never fires on separation
            local wx0, wy0, wz0, wx1, wy1, wz1 = part_wake_box(part, 1)
            wake_sleepers_overlapping(world, wx0, wy0, wz0, wx1, wy1, wz1)
        end
        -- caches keyed to the previous static-ness of this body are wrong
        body._static_member_cache = nil
        body._static_member_grid = nil
        body._query_member_grid = nil
        -- the com-sphere radius may have been cached during an earlier dynamic
        -- stint with a different Size (nothing consults it while static) -- drop it
        -- so the first upsert after the flip re-derives from live geometry
        body._bp_radius = nil
        body._bp_radius_key = nil
        body._bp_tight_key = nil
        -- contacts (incl. warm-start impulses) against the old state are invalid
        if world.manifold_cache then
            world.manifold_cache:remove_for_part(part._id)
            note_filter_clear(world)
        end
        world.collision_dirty = true
        part.AssemblyMass = asm.mass
        part.AssemblyCenterOfMass = { x = asm.com_x, y = asm.com_y, z = asm.com_z }
        return true
    end

    function RBX:_note_runtime_part_physics_transform_changed(part, pose_only)
        if type(part) ~= "table" or not part._id then
            return
        end
        -- setters fire constantly during import, no world = cheap map load
        local world = self._physics_world
        if not world then
            return
        end
        if pose_only and self.physics_enabled == true
            and try_inplace_part_teleport(self, world, part) then
            return
        end
        -- static singleton motion changes pose, not topology
        if pose_only and self.physics_enabled == true
            and try_inplace_static_singleton_pose(self, world, part) then
            return
        end
        -- non-pose change (Size etc.) on a bound clean singleton: full in-place
        -- geometry refresh -- without this every post-registration Size write forced
        -- the whole-world rebuild (npc.lua resizes pooled parts on giant respawns)
        if not pose_only and self.physics_enabled == true
            and self:_try_inplace_singleton_geometry_refresh(world, part) then
            return
        end
        -- a part the built topology doesn't know about can't invalidate it: initial
        -- property writes during _create_runtime_part land here BEFORE registration,
        -- and dirtying now forces the whole-world rebuild the registration's
        -- incremental singleton add exists to avoid. Registration owns the decision
        if world.assemblies_built and not world.assembly_dirty
            and world.part_to_assembly and world.part_to_assembly[part._id] == nil then
            return
        end
        world:mark_assembly_dirty()
        self._physics_assembly_dirty = true
    end

    -- cancollide/collisiongroup changed -> re-filter pairs next step
    function RBX:_on_runtime_part_collision_changed(part)
        if type(part) ~= "table" or not part._id then
            return
        end
        local world = self._physics_world
        if not world then
            return
        end
        world.collision_dirty = true
        -- drop cached contacts so the change applies same-frame
        if world.manifold_cache and part._id ~= nil then
            world.manifold_cache:remove_for_part(part._id)
            note_filter_clear(world)
        end
        -- manifold filter reads these off the bind-time view, for a lone part that's the whole update
        if self.physics_enabled == true and not world.assembly_dirty then
            local asm = world.part_to_assembly and world.part_to_assembly[part._id]
            local members = asm and asm.parts
            if members and #members == 1 and members[1] and members[1]._part == part then
                members[1].CanCollide = part.CanCollide
                members[1].CollisionGroup = part.CollisionGroup
                if part.CanCollide == false then
                    -- rebuild force-woke everything, in place we must wake explicitly or it falls through / sleepers lose support
                    local body = asm.body
                    if body and body.sleeping then
                        world:wake_body(body)
                    end
                    local wx0, wy0, wz0, wx1, wy1, wz1 = part_wake_box(part, 1)
                    wake_sleepers_overlapping(world, wx0, wy0, wz0, wx1, wy1, wz1)
                end
                return
            end
        end
        -- unbound part on a clean built world: nothing in the topology references it
        -- (initial property writes during _create_runtime_part land here BEFORE
        -- registration) -- let registration decide, don't force a whole-world rebuild
        if world.assemblies_built and not world.assembly_dirty
            and world.part_to_assembly and world.part_to_assembly[part._id] == nil then
            return
        end
        world:mark_assembly_dirty()
        self._physics_assembly_dirty = true
    end

    -- topology props that dont affect mass (rootpriority), re-derives root + inertia
    function RBX:_on_runtime_part_assembly_property_changed(part)
        if type(part) ~= "table" or not part._id then
            return
        end
        local world = self._physics_world
        if not world then
            return
        end
        -- same unbound-part guard as the transform/collision hooks above
        if world.assemblies_built and not world.assembly_dirty
            and world.part_to_assembly and world.part_to_assembly[part._id] == nil then
            return
        end
        world:mark_assembly_dirty()
        self._physics_assembly_dirty = true
    end

    -- activation-mode apis

    -- permanently woken, so rebuilds keep it awake
    function RBX:_wake_physics_part(part)
        if type(part) ~= "table" or part._id == nil then
            return
        end
        track_woken(self, part)
        local world = self._physics_world
        if not world then
            return
        end
        local asm = world.part_to_assembly[part._id]
        if asm and asm.body and not asm.body.is_static then
            asm.body:wake()
        end
    end

    function RBX:_wake_physics_assembly(assembly)
        if type(assembly) ~= "table" then
            return
        end
        local body = assembly.body
        if body and not body.is_static then
            body:wake()
            self._physics_woken_part_ids = self._physics_woken_part_ids or {}
            local members = assembly.parts or {}
            for i = 1, #members do
                local v = members[i]
                if v.id ~= nil then
                    self._physics_woken_part_ids[v.id] = true
                end
            end
        end
    end

    -- drops members from the woken set so the next rebuild respects activation mode
    function RBX:_sleep_physics_assembly(assembly)
        if type(assembly) ~= "table" then
            return
        end
        local body = assembly.body
        if body and not body.is_static then
            body:sleep()
            local woken = self._physics_woken_part_ids
            if woken then
                local members = assembly.parts or {}
                for i = 1, #members do
                    woken[members[i].id] = nil
                end
            end
        end
    end

    -- survives assembly rebuilds
    function RBX:_activate_runtime_part(part)
        if type(part) ~= "table" or part._id == nil then
            return
        end
        self._physics_explicitly_activated_part_ids = self._physics_explicitly_activated_part_ids or {}
        self._physics_explicitly_activated_part_ids[part._id] = true
        track_woken(self, part)
        local world = self._physics_world
        if not world then
            return
        end
        local asm = world.part_to_assembly[part._id]
        if asm and asm.body and not asm.body.is_static then
            asm.body:wake()
        end
    end

    -- step & diagnostics

    function RBX:_step_physics(dt)
        -- whole-step wall time, one gettime() pair/frame. read via core._last_physics_total_ms
        local _phys_step_started_at = love.timer.getTime()
        local observer = self._physics_profile_observer
        if self.physics_enabled ~= true then
            if observer then observer:before_step(self, nil, dt) end
            self._last_physics_total_ms = (love.timer.getTime() - _phys_step_started_at) * 1000
            if observer then observer:after_step(self, nil) end
            return
        end

        local world = ensure_world(self)
        apply_physics_config(self, world)
        local _t_config = love.timer.getTime()
        -- before ensure_assemblies so the wake classifier sees mover-driven parts
        sync_movers(self, world)
        local _t_movers = love.timer.getTime()
        ensure_assemblies(self)
        local _t_assemblies = love.timer.getTime()
        -- needs static proxies to exist, airborne loaded assemblies wake, supported stay asleep
        apply_support_aware_initial_state(self, world)
        Rope.sync(self, world)
        local _t_support = love.timer.getTime()
        if observer then observer:before_step(self, world, dt) end
        if self._fixed_heartbeat then
            self._fixed_heartbeat_step = self._fixed_heartbeat_step or function(step_world, step_dt)
                -- public queries and controller reads must see the preceding
                -- substep, including during a multi-step update
                write_back_active(self, step_world, Physics._deps)
                fire_rbx_script_signal(self._fixed_heartbeat, step_dt)
                ensure_assemblies(self)
                sync_movers(self, step_world)
                -- the callback can move anchored rig pieces or change topology
                -- Such a rebuild replaces loaded bodies after World:step's wake
                -- pass, so rebind dependencies before this substep consumes them
                Rope.sync(self, step_world)
                step_world.movers:wake_targets(step_world)
                if step_world.active_dirty then step_world:refresh_active() end
            end
            world.before_fixed_step = self._fixed_heartbeat_step
        else
            world.before_fixed_step = nil
        end
        local touch_listeners = self._touch_listener_ids
        if touch_listeners and next(touch_listeners) ~= nil then
            self._touch_fixed_step = self._touch_fixed_step or function(step_world)
                -- Observe every admitted step, including contacts beginning and
                -- ending between two rendered frames. Delivery remains deferred
                -- until DataModel:update returns from the complete physics batch
                write_back_active(self, step_world, Physics._deps)
                for i = 1, step_world.active_count do
                    step_world.broadphase:upsert_dynamic(step_world.active_bodies[i])
                end
                run_touch_events(self, step_world, true)
            end
            world.after_fixed_step = self._touch_fixed_step
        else
            world.after_fixed_step = nil
        end
        local substeps = world:step(dt)
        local _t_step = love.timer.getTime()
        self._last_physics_config_ms = (_t_config - _phys_step_started_at) * 1000
        self._last_physics_movers_ms = (_t_movers - _t_config) * 1000
        self._last_physics_assemblies_ms = (_t_assemblies - _t_movers) * 1000
        self._last_physics_support_ms = (_t_support - _t_assemblies) * 1000
        self._last_physics_world_step_ms = (_t_step - _t_support) * 1000
        if substeps > 0 then
            -- only when the sim actually advanced
            write_back_active(self, world, Physics._deps)
            apply_fallen_parts_destroy_height(self, world)
            demote_settled_promoted_parts(self, world, Physics._deps)
            -- a real substep upserted every dynamic part. only when substeps>0 -- on an idle frame they stay unhashed and must stay pending
            if self._physics_pending_query_parts and next(self._physics_pending_query_parts) then
                self._physics_pending_query_parts = {}
                self._query_extras_epoch = (self._query_extras_epoch or 0) + 1
            end
        end
        -- Followers consume this update's interval, including idle-clock ticks
        -- Publishing after them delays motion and reuses time on a zero-delta update
        local advanced_substeps = substeps > 0 and substeps or (world.last_idle_substeps or 0)
        self._physics_last_dt = advanced_substeps * world.config.fixed_dt
        if not world.after_fixed_step or substeps == 0 then
            run_touch_events(self, world, advanced_substeps > 0)
        end
        apply_motor_followers(self, world, Physics._deps)
        apply_rotate_joints(self, world, Physics._deps)
        self._physics_step_count = world.step_count
        self._last_physics_total_ms = (love.timer.getTime() - _phys_step_started_at) * 1000
        self._last_physics_tail_ms = self._last_physics_total_ms
            - (self._last_physics_config_ms or 0) - (self._last_physics_movers_ms or 0)
            - (self._last_physics_assemblies_ms or 0) - (self._last_physics_support_ms or 0)
            - (self._last_physics_world_step_ms or 0)
        self._last_physics_substeps = substeps
        self._last_physics_active_count = world.active_count or 0
        self._last_physics_member_tests = world.member_test_count or 0
        self._last_physics_member_survivors = world.member_survivor_count or 0
        self._last_physics_pair_count = world.broadphase_pair_count or 0
        self._last_physics_candidate_checks = world.candidate_check_count or 0
        self._last_physics_contact_count = world.contact_count or 0
        self._last_physics_manifold_count = world.manifold_active_count or 0
        self._last_physics_static_proxies = world.static_proxy_count or 0
        self._last_physics_dynamic_proxies = world.dynamic_proxy_count or 0
        self._last_physics_broadphase_ms = world.broadphase_ms or 0
        self._last_physics_narrowphase_ms = world.narrowphase_ms or 0
        self._last_physics_solver_ms = world.solver_ms or 0
        if observer then observer:after_step(self, world) end
    end

end

return Physics
