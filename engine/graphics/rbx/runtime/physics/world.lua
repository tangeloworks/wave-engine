-- physics world: fixed-timestep, owns bodies/assemblies/diagnostics
-- step order: gravity->broadphase->narrowphase->solver->integrate, statics built once

local Integrate       = runtime_require("physics/integrate.lua")
local Shape           = runtime_require("physics/shape.lua")
local Continuous      = runtime_require("physics/continuous.lua")
local Broadphase      = runtime_require("physics/broadphase.lua")
local ManifoldCache   = runtime_require("physics/manifold.lua")
local Solver          = runtime_require("physics/solver.lua")
local Movers          = runtime_require("physics/movers.lua")
local CollisionGroups = runtime_require("physics/collision_groups.lua")

local Rope = runtime_require("physics/rope.lua")
local World = {}
World.__index = World

local EPSILON = 1e-7
local PROFILE_STEP_COUNTERS = {"broadphase_ms","narrowphase_ms","solver_ms","mover_ms",
    "contact_count","broadphase_pair_count","candidate_check_count","member_test_count",
    "member_node_visits","member_tree_builds","member_tree_refits","member_tree_fallbacks",
    "rope_active_rows","rope_enforced_rows","rope_impulse_sum","rope_solve_ms"}

local function clamp(value, lo, hi)
    value = tonumber(value) or 0
    if value < lo then return lo end
    if value > hi then return hi end
    return value
end

local function normalize_config(config)
    config = config or {}
    return {
        enabled           = config.enabled == true,
        collision_enabled = config.collision_enabled == true,
        activation_mode   = config.activation_mode or "viewer",
        fixed_dt          = clamp(config.fixed_dt or (1 / 60), 1 / 240, 1 / 15),
        max_substeps      = math.max(1, math.floor(tonumber(config.max_substeps) or 8)),
        max_frame_dt      = clamp(config.max_frame_dt or 0.25, 1 / 120, 1),
        gravity           = tonumber(config.gravity) or 196.2,
        -- velocity_iterations=0 = detection-only
        velocity_iterations = math.max(0, math.floor(tonumber(config.velocity_iterations) or 8)),
        position_iterations = math.max(0, math.floor(tonumber(config.position_iterations) or 3)),
        baumgarte         = tonumber(config.baumgarte) or 0.2,
        contact_slop      = tonumber(config.contact_slop) or 0.01,
        -- under thresholds for sleep_time secs = sleep, wake_speed_threshold 0 = derive from gravity
        sleeping_enabled        = config.sleeping_enabled ~= false,
        sleep_linear_threshold  = math.max(0, tonumber(config.sleep_linear_threshold) or 0.25),
        sleep_angular_threshold = math.max(0, tonumber(config.sleep_angular_threshold) or 0.05),
        sleep_time              = math.max(0, tonumber(config.sleep_time) or 0.5),
        wake_speed_threshold    = math.max(0, tonumber(config.wake_speed_threshold) or 0),
        -- wall-clock ms, 0=unlimited, over budget drops leftover (anti spiral-of-death), first substep always runs
        budget_ms = math.max(0, tonumber(config.budget_ms) or 0),
        -- internal only, caps velocity so a bad contact cant blow up, distinct from the 1e6 finiteness guard
        max_linear_velocity  = math.max(1, tonumber(config.max_linear_velocity) or 4000),
        max_angular_velocity = math.max(0.1, tonumber(config.max_angular_velocity) or 100),
        -- Deep sleep tolerates small resting pose jitter, including rotation, 0 disables
        deep_sleep_time      = math.max(0, tonumber(config.deep_sleep_time) or 1.0),
        deep_sleep_tolerance = math.max(0, tonumber(config.deep_sleep_tolerance) or 0.12),
        -- swept-aabb vs static for fast bodies
        ccd_enabled = config.ccd_enabled ~= false,
    }
end

local function solver_params(config)
    return {
        velocity_iterations = config.velocity_iterations,
        position_iterations = config.position_iterations,
        baumgarte           = config.baumgarte,
        slop                = config.contact_slop,
        -- solver derives wake threshold from these + gravity*dt
        sleep_linear_threshold = config.sleep_linear_threshold,
        wake_speed_threshold   = config.wake_speed_threshold,
    }
end

local function get_time()
    if rawget(_G, "love") and love.timer and love.timer.getTime then
        return love.timer.getTime()
    end
    return os.clock()
end

function World.new(config)
    local self = setmetatable({}, World)
    self.config = normalize_config(config)

    self.ropes = {}
    self.rope_diagnostics = {}
    self._rope_topology_revision = 0
    -- topology
    self.bodies         = {}
    self.assemblies     = {}
    self.assemblies_by_id = {}
    self.part_to_assembly = {}
    -- both read live, a filter change clears contacts, doesnt wake
    self.no_collision         = {}
    self.no_collision_runtime = {}
    self.collision_groups     = CollisionGroups.new()

    -- dense active array (non-static/sleeping), sleep/wake are o(1) swap-remove/append
    self.active_bodies  = {}
    self.active_count   = 0
    self.active_dirty   = true   -- force first refresh

    -- wake queue, drained at end of fixed_step, dup enqueues ok
    self._pending_wake       = {}
    self._pending_wake_count = 0

    -- accumulator
    -- Lifetime accounting survives reset, reset explicitly retires its remainder
    self.time_accounting = {input_seconds=0,admitted_seconds=0,frame_clamp_seconds=0,
        disabled_seconds=0,step_cap_seconds=0,budget_seconds=0,reset_seconds=0,
        simulated_seconds=0,executed_steps=0,idle_steps=0,invalid_inputs=0,reset_events=0}
    self.accumulator    = 0
    self.step_count     = 0
    self.step_index     = 0
    self.last_substeps  = 0

    -- sleep/wake + budget diagnostics (cumulative unless noted)
    self.sleep_candidate_count       = 0   -- per step
    self.auto_sleep_count            = 0
    self.wake_event_count            = 0
    self.wake_propagation_count      = 0   -- wakes caused by contact
    self.sleeping_proxy_count        = 0
    self.step_wall_ms                = 0   -- ms, substep loop this frame
    self.substeps_attempted          = 0   -- wanted this frame
    self.substeps_completed          = 0   -- actually run this frame
    self.budget_exceeded_count       = 0   -- frames, not substeps
    self.accumulator_dropped_count   = 0   -- frames leftover discarded
    self.accumulator_dropped_seconds = 0   -- sim-time discarded

    -- broadphase
    self.broadphase              = Broadphase.new()
    self.broadphase_statics_dirty = true   -- build static hash on first step
    self.broadphase_pairs         = {}

    -- narrowphase / contacts
    self.manifold_cache = ManifoldCache.new()

    -- contact solver
    self.solver = Solver.new(solver_params(self.config))

    -- movers
    self.movers = Movers.new()
    self.mover_ms            = 0
    self.mover_active_count  = 0
    self.mover_applied_count = 0

    -- per-step diagnostics, reset each fixed_step
    self.solver_ms            = 0
    self.solver_contact_count = 0
    self.solver_velocity_iterations = 0
    self.solver_position_iterations = 0
    self.broadphase_ms        = 0
    self.narrowphase_ms       = 0
    self.broadphase_pair_count = 0
    self.contact_count         = 0

    -- broadphase sub-counters, mirrored each step
    self.static_proxy_count    = 0
    self.dynamic_proxy_count   = 0
    self.dirty_proxy_count     = 0
    self.proxy_upsert_count    = 0
    self.candidate_check_count = 0

    -- manifold sub-counters, mirrored each step
    self.manifold_cache_count  = 0
    self.manifold_active_count = 0
    self.manifold_pruned_count = 0

    -- collision-filter sub-counters, per step
    self.collision_filter_pair_rejects = 0
    self.can_collide_pair_rejects      = 0
    self.collision_group_pair_rejects  = 0
    -- cumulative
    self.contact_cache_clears_from_filter_change = 0

    -- set by host glue's apply_activation_mode
    self.wake_suppressed_count = 0

    -- bodies snapped to a static this step
    self.ccd_clamp_count = 0

    -- render-sync counters
    self.transform_updates_from_physics  = 0
    self.full_render_rebuilds_from_physics = 0

    -- topology diagnostics, *_count monotonic across rebuilds, rest refreshed per rebuild
    self.assembly_rebuild_count         = 0  -- cumulative
    self.topology_dirty_count           = 0  -- cumulative, clean->dirty only
    self.rigid_joint_count              = 0  -- last rebuild
    self.unsupported_joint_count        = 0  -- last rebuild
    self.largest_assembly_part_count    = 0
    self.anchored_static_assembly_count = 0

    self.assembly_dirty  = true
    self.collision_dirty = false
    self.assemblies_built = false
    return self
end

function World:set_config(config)
    self.config = normalize_config(config)
    if self.solver then
        self.solver:configure(solver_params(self.config))
    end
    return self.config
end

function World:mark_assembly_dirty()
    -- count clean->dirty only, not redundant calls
    if not self.assembly_dirty then
        self.topology_dirty_count = (self.topology_dirty_count or 0) + 1
    end
    self.assembly_dirty = true
end

-- once per rebuild from set_assemblies, never per frame
function World:recompute_assembly_stats()
    local assemblies = self.assemblies or {}
    local largest = 0
    local anchored_static = 0
    for index = 1, #assemblies do
        local asm = assemblies[index]
        local pc = asm.part_count or (asm.parts and #asm.parts) or 0
        if pc > largest then
            largest = pc
        end
        if asm.anchored == true or (asm.body and asm.body.is_static) then
            anchored_static = anchored_static + 1
        end
    end
    self.largest_assembly_part_count = largest
    self.anchored_static_assembly_count = anchored_static
end

-- takes assembly.build output
function World:set_assemblies(result)
    for _,body in ipairs(self.bodies) do ManifoldCache.release_member_ranges(body) end
    self:clear_sleep_pose_publications()
    self.ropes = {}
    self._rope_bound_revision = nil
    self._rope_topology_revision = (self._rope_topology_revision or 0) + 1
    result = result or {}
    self.assemblies       = result.assemblies    or {}
    self.assemblies_by_id = result.assemblies_by_id or {}
    self.part_to_assembly = result.part_to_assembly or {}
    self.bodies           = result.bodies        or {}
    self.assemblies_built = true
    self.assembly_dirty   = false

    -- bodies recreated every rebuild, old active_index points at dead bodies
    local bodies = self.bodies
    for i = 1, #bodies do
        local b = bodies[i]
        b.world = self
        b.active_index = 0
        b.sleep_timer = 0
        b._body_world_index = i
    end
    -- dense-index back-pointers (mirror body.active_index) so remove_singleton_assembly
    -- can splice by O(1) index instead of scanning every assembly/body to find it
    local asms = self.assemblies
    for i = 1, #asms do
        asms[i]._world_index = i
    end
    self.active_count = 0
    self.active_dirty = true
    self._pending_wake_count = 0

    self.broadphase_statics_dirty = true
    self.broadphase:reset_dynamics()
    self.broadphase:reset_sleeping()
    self.sleeping_proxy_count = 0
    self.broadphase_pairs = {}

    -- old manifolds hold stale refs, also the destroy/cancollide/group invalidation path
    self.manifold_cache:clear()

    self:recompute_assembly_stats()
    return self
end

-- on demand for support-aware bind, before fixed_step's lazy build, idempotent
function World:ensure_static_proxies()
    if not self.config.collision_enabled then
        return
    end
    if not self.broadphase_statics_dirty then
        return
    end
    local bp = self.broadphase
    bp:reset_statics()
    local asms = self.assemblies
    for i = 1, #asms do
        local asm = asms[i]
        if asm.body and asm.body.is_static then
            bp:insert_static(asm)
        end
    end
    self.broadphase_statics_dirty = false
end

-- assigns active_index so swap-removes stay coherent, only runs on active_dirty
function World:refresh_active()
    local bodies = self.bodies or {}
    local active = self.active_bodies
    local bp = self.broadphase
    bp:reset_sleeping()
    self.sleeping_proxy_count = 0
    local n = 0
    for index = 1, #bodies do
        local body = bodies[index]
        if body.is_static then
            body.active_index = 0
        elseif body.sleeping then
            body.active_index = 0
            -- kinematic motor6d followers sleep but still move, proxy would go stale
            if not body.kinematic then
                bp:insert_sleeping(body)
            end
        else
            n = n + 1
            active[n] = body
            body.active_index = n
        end
    end
    self.active_count = n
    self.sleeping_proxy_count = bp.sleeping_proxy_count or 0
    self.active_dirty = false
    return n
end

-- o(1) append, idempotent
function World:add_active(body)
    if body.active_index ~= 0 or body.is_static then
        return
    end
    local n = self.active_count + 1
    self.active_bodies[n] = body
    body.active_index = n
    self.active_count = n
end

-- o(1) swap-remove, tail slot left stale on purpose, iterate 1..active_count not #active_bodies
function World:remove_active(body)
    local i = body.active_index
    if i == 0 then
        return
    end
    local last = self.active_count
    local lb = self.active_bodies[last]
    self.active_bodies[i] = lb
    if lb then lb.active_index = i end
    self.active_count = last - 1
    body.active_index = 0
end

-- remove one already-bound singleton assembly without invalidating every other body
-- host glue performs semantic dependency checks (joints/movers/followers), this method
-- independently verifies all world-owned references before mutating anything
function World:remove_singleton_assembly(part_id)
    self.ropes = {}
    self._rope_bound_revision = nil
    self._rope_topology_revision = (self._rope_topology_revision or 0) + 1
    if not self.assemblies_built then return false, "world_not_built" end
    if self.assembly_dirty then return false, "topology_dirty" end
    if part_id == nil then return false, "missing_part_id" end

    local part_map = self.part_to_assembly
    local asm = part_map and part_map[part_id]
    if not asm then return false, "missing_assembly" end
    local members = asm.parts
    local body = asm.body
    if not members or #members ~= 1 or asm.part_count ~= 1 then
        return false, "not_singleton"
    end
    local member = members[1]
    if not member or member.id ~= part_id or not body
        or body.assembly ~= asm or body.parts ~= members or body.part_count ~= 1
        or body.id ~= asm.id or self.assemblies_by_id[asm.id] ~= asm
        or body.world ~= self then
        return false, "inconsistent_singleton"
    end

    -- remove a body or assembly by moving the last live entry into its slot
    -- update that entry’s index so later removals still find it
    local assemblies = self.assemblies
    local asm_index = asm._world_index or 0
    if asm_index < 1 or asm_index > #assemblies or assemblies[asm_index] ~= asm then
        return false, "assembly_index_stale"
    end
    local bodies = self.bodies
    local body_index = body._body_world_index or 0
    if body_index < 1 or body_index > #bodies or bodies[body_index] ~= body then
        return false, "body_index_stale"
    end

    -- a queued wake is a phase-owned reference. Falling back lets the normal rebuild run
    -- after the phase boundary rather than mutating a body still scheduled for work
    local pending = self._pending_wake
    for _, queued_body in pairs(pending) do
        if queued_body == body then return false, "pending_wake" end
    end

    -- validate active membership before changing it. Sleeping transitions may leave the
    -- array dirty, but no live-range alias is allowed outside active_index
    local active = self.active_bodies
    local active_hits = 0
    for i = 1, self.active_count do
        if active[i] == body then active_hits = active_hits + 1 end
    end
    local active_index = body.active_index or 0
    if (active_index ~= 0 and (active_index < 1 or active_index > self.active_count
            or active_hits ~= 1 or active[active_index] ~= body))
        or (active_index == 0 and active_hits ~= 0) then
        return false, "inconsistent_active_membership"
    end

    -- current broadphase pairs hold pooled tuples, so compact them before clearing the
    -- pool's retained body references
    local pairs_out = self.broadphase_pairs
    local pair_write, removed_pairs = 1, 0
    for i = 1, #pairs_out do
        local pair = pairs_out[i]
        if pair and (pair[1] == body or pair[2] == body) then
            removed_pairs = removed_pairs + 1
        else
            pairs_out[pair_write] = pair
            pair_write = pair_write + 1
        end
    end
    for i = pair_write, #pairs_out do pairs_out[i] = nil end

    local cache = self.manifold_cache
    local removed_manifolds = cache and cache:remove_for_part(part_id) or 0
    if self.solver and self.solver.forget_body then self.solver:forget_body(body) end

    local old_active_count = self.active_count
    self:remove_active(body)
    if old_active_count > self.active_count then
        active[old_active_count] = nil
    end
    -- Body:sleep() intentionally leaves preallocated tail slots. Destruction is rare and
    -- must release the dead body completely, so scrub any inactive-tail reference too
    for i, candidate in pairs(active) do
        if i > self.active_count and candidate == body then active[i] = nil end
    end

    local bp = self.broadphase
    bp:remove_static(body.id)
    bp:remove_dynamic(body.id)
    bp:remove_sleeping(body.id)
    bp:forget_body(body)

    -- O(1) swap-remove keeping _world_index / _body_world_index consistent (was
    -- table.remove, an O(n) middle shift of the whole assembly/body array per destroy)
    local asm_was_static = asm.anchored == true or (body and body.is_static)
    local last_a = #assemblies
    if asm_index ~= last_a then
        local moved = assemblies[last_a]
        assemblies[asm_index] = moved
        if moved then moved._world_index = asm_index end
    end
    assemblies[last_a] = nil
    asm._world_index = nil
    local last_b = #bodies
    if body_index ~= last_b then
        local moved_body = bodies[last_b]
        bodies[body_index] = moved_body
        if moved_body then moved_body._body_world_index = body_index end
    end
    bodies[last_b] = nil
    body._body_world_index = nil
    ManifoldCache.release_member_ranges(body)
    self:remove_sleep_pose_publication(body)
    part_map[part_id] = nil
    self.assemblies_by_id[asm.id] = nil
    if self._forced_awake then self._forced_awake[body] = nil end
    if self._newly_freed_assemblies then self._newly_freed_assemblies[asm] = nil end
    if self.movers and self.movers.forget_body then self.movers:forget_body(body) end

    -- Break the removed topology's back-references after all removal helpers have read it
    members[1] = nil
    asm.parts, asm.part_count, asm.root_part, asm.body = members, 0, nil, nil
    body.parts, body.part_count, body.local_offsets = members, 0, {}
    body.assembly, body.world, body.active_index = nil, nil, 0

    self.broadphase_pair_count = #pairs_out
    bp.broadphase_pair_count = #pairs_out
    self.static_proxy_count = bp.static_proxy_count
    self.dynamic_proxy_count = bp.dynamic_proxy_count
    self.sleeping_proxy_count = bp.sleeping_proxy_count
    if cache then
        self.contact_count = cache.contact_count or 0
        self.manifold_cache_count = cache.cache_count or 0
        self.manifold_active_count = cache.active_count or 0
        self.manifold_pruned_count = cache.pruned_count or 0
        self.solver_contact_count = cache.contact_count or 0
    end
    -- incremental stats (diagnostic-only counters) -- a full recompute_assembly_stats()
    -- here would rescan every assembly on each destroy. removing a singleton (part_count 1)
    -- can never raise largest_assembly_part_count, so the stored value stays a valid bound
    if asm_was_static then
        self.anchored_static_assembly_count = math.max(0, (self.anchored_static_assembly_count or 1) - 1)
    end
    self.static_anchored_assembly_count = self.anchored_static_assembly_count
    return true, removed_pairs, removed_manifolds
end

-- insert one freshly built singleton assembly (Assembly.build output for exactly one
-- part) without invalidating every other body -- counterpart to
-- remove_singleton_assembly. host glue owns the semantic guards (no joints/movers/
-- followers may reference the part), this only verifies world-owned invariants
-- Rationale: the alternative is mark_assembly_dirty -> whole-world ensure_assemblies,
-- which allocates a plain_view for every part (~180MB / 200-800ms at 48k parts) on
-- every runtime part creation (NPC spawns etc.)
function World:add_singleton_assembly(asm)
    self.ropes = {}
    self._rope_bound_revision = nil
    self._rope_topology_revision = (self._rope_topology_revision or 0) + 1
    if not self.assemblies_built then return false, "world_not_built" end
    if self.assembly_dirty then return false, "topology_dirty" end
    local body = asm and asm.body
    local members = asm and asm.parts
    if not body or not members or #members ~= 1 or asm.part_count ~= 1 then
        return false, "not_singleton"
    end
    local member = members[1]
    local part_id = member and member.id
    if part_id == nil or asm.id == nil then return false, "missing_ids" end
    if self.part_to_assembly[part_id] ~= nil then return false, "part_already_bound" end
    if self.assemblies_by_id[asm.id] ~= nil then return false, "id_taken" end

    body.world = self
    body.active_index = 0
    body.sleep_timer = 0
    self.assemblies[#self.assemblies + 1] = asm
    asm._world_index = #self.assemblies
    self.assemblies_by_id[asm.id] = asm
    self.part_to_assembly[part_id] = asm
    self.bodies[#self.bodies + 1] = body
    body._body_world_index = #self.bodies

    if body.is_static then
        -- mirror ensure_static_proxies: when statics are already clean, splice the
        -- proxy directly, when dirty, the pending full static rebuild includes it
        if self.config.collision_enabled and not self.broadphase_statics_dirty then
            self.broadphase:insert_static(asm)
            self.static_proxy_count = self.broadphase.static_proxy_count
        end
    else
        -- Body.new is born awake, enter the active set directly (fixed_step upserts
        -- its dynamic broadphase proxy on the next step)
        self:add_active(body)
    end
    -- incremental stats (diagnostic-only counters) -- a full recompute_assembly_stats()
    -- here would rescan every assembly on each runtime part spawn (NPCs etc.)
    if asm.anchored == true or body.is_static then
        self.anchored_static_assembly_count = (self.anchored_static_assembly_count or 0) + 1
    end
    local add_pc = asm.part_count or 1
    if add_pc > (self.largest_assembly_part_count or 0) then
        self.largest_assembly_part_count = add_pc
    end
    self.static_anchored_assembly_count = self.anchored_static_assembly_count
    return true
end

-- hot path: no active_dirty needed, invariant kept directly
-- a solver sleep removes a body from active_bodies before the host publishes
-- poses. keep only this step's unique transitions, never scan sleeping bodies
function World:queue_sleep_pose_publication(body)
    if body._sleep_pose_index then return end
    local pending = self.sleep_pose_publications
    if not pending then pending = {}; self.sleep_pose_publications = pending end
    local n = #pending + 1
    pending[n], body._sleep_pose_index = body, n
end

function World:remove_sleep_pose_publication(body)
    local i = body._sleep_pose_index
    if not i then return end
    local pending = self.sleep_pose_publications
    local last = #pending
    local moved = pending[last]
    pending[i] = moved
    moved._sleep_pose_index = i
    pending[last], body._sleep_pose_index = nil, nil
end

function World:clear_sleep_pose_publications()
    local pending = self.sleep_pose_publications
    if not pending then return end
    for i = #pending, 1, -1 do
        pending[i]._sleep_pose_index = nil
        pending[i] = nil
    end
end

function World:sleep_body(body)
    if body.is_static or body.sleeping then
        return
    end
    body.sleeping = true
    body._sleep_step = self.step_index
    body.sleep_timer = 0
    body.vx, body.vy, body.vz = 0, 0, 0
    body.wx, body.wy, body.wz = 0, 0, 0
    self:remove_active(body)
    local bp = self.broadphase
    bp:remove_dynamic(body.id)
    if not body.kinematic then
        bp:insert_sleeping(body)
    end
    self.sleeping_proxy_count = bp.sleeping_proxy_count or 0
end

-- publish the current dynamic proxy at the sleep/wake boundary. Queries can run
-- before the next fixed step (including update(0)), removing only the sleeping
-- proxy leaves an awake body absent from all three spatial hashes in that gap
-- propagated = contact-caused
function World:wake_body(body, propagated)
    if body.is_static or not body.sleeping then
        return
    end
    body.sleeping = false
    body._step_gravity_vy = 0
    body.sleep_timer = 0
    -- re-woken body re-accumulates deep-sleep from here
    body.deep_timer = 0
    body.deep_ref_x = nil
    body.deep_ref_qw = nil
    body.deep_slept = false
    self:add_active(body)
    local bp = self.broadphase
    bp:remove_sleeping(body.id)
    bp:upsert_dynamic(body)
    self.sleeping_proxy_count = bp.sleeping_proxy_count or 0
    self.wake_event_count = self.wake_event_count + 1
    if propagated then
        self.wake_propagation_count = self.wake_propagation_count + 1
    end
end

-- Park-to-sleep tier for far NPCs: an immediate external sleep, O(1) both ways
-- a parked body leaves ALL per-substep work (no gravity, broadphase upsert, candidate
-- scan, manifolds, solver) but keeps a rest-pose sleeping proxy, so awake bodies still
-- collide with it, raycasts still hit it, impact-wake and support-release wake still
-- fire. caller contract: only park a GROUNDED body (a parked airborne body hangs
-- mid-air until something wakes it), unpark needs no re-snap -- statics never moved,
-- so gravity re-settles it onto its contact next substep. call from game update only,
-- never mid-fixed_step (same discipline as every other cold entry point)
function World:park_body(body)
    if body == nil or body.is_static or body.sleeping then
        return false
    end
    self:sleep_body(body)
    return true
end

function World:unpark_body(body)
    if body == nil or body.is_static or not body.sleeping then
        return false
    end
    self:wake_body(body)
    return true
end

-- wake at end of fixed_step, never mid-phase (phase arrays stay unmutated)
function World:enqueue_wake(body)
    if body == nil or body.is_static or not body.sleeping or body._wake_queued then
        return
    end
    body._wake_queued = true
    local n = self._pending_wake_count + 1
    self._pending_wake[n] = body
    self._pending_wake_count = n
end

function World:body_counts()
    local dynamic, static, sleeping = 0, 0, 0
    local bodies = self.bodies or {}
    for index = 1, #bodies do
        local body = bodies[index]
        if body.is_static then
            static = static + 1
        elseif body.sleeping then
            sleeping = sleeping + 1
        else
            dynamic = dynamic + 1
        end
    end
    return dynamic, static, sleeping
end

-- collider audit (read-only)

-- proxy id == assembly id, nil = orphan/stale
function World:assembly_for_proxy(id)
    local by_id = self.assemblies_by_id
    return by_id and by_id[id] or nil
end

-- source: stale-orphan / parsed-rbxl / runtime-created
function World:audit_proxies()
    local out = {}
    local bp = self.broadphase
    if not bp or not bp.for_each_proxy then return out end
    bp:for_each_proxy(function(kind, id, aabb)
        local asm = self:assembly_for_proxy(id)
        local body = asm and asm.body or nil
        local root = asm and asm.root_part or nil
        local record = root and (root._part or root) or nil
        local source
        if not asm or (record and record._destroyed == true) then
            source = "stale-orphan"
        elseif record and record._loaded_from_map == true then
            source = "parsed-rbxl"
        else
            source = "runtime-created"
        end
        out[#out + 1] = {
            kind = kind, id = id, aabb = aabb,
            assembly = asm, body = body, root_part = root, record = record,
            source = source,
        }
    end)
    return out
end

-- half-extents around com at current orientation, sizes ccd's swept volume so a flat plate lands flush
local function body_aabb_half(b)
    local offs = b.local_offsets
    if not offs or #offs == 0 then
        -- use the root part extents for an unbound body
        local asm = b.assembly
        local root = asm and asm.root_part
        if root then
            return Shape.half_extents(root)
        end
        return 2, 2, 2
    end
    local qw, qx, qy, qz = b.qw, b.qx, b.qy, b.qz
    local r00, r01, r02, r10, r11, r12, r20, r21, r22 = Integrate.quat_to_matrix(qw, qx, qy, qz)
    local lo_x, lo_y, lo_z =  math.huge,  math.huge,  math.huge
    local hi_x, hi_y, hi_z = -math.huge, -math.huge, -math.huge
    local mabs = math.abs
    for i = 1, #offs do
        local o = offs[i]
        local lx, ly, lz = o.lx, o.ly, o.lz
        local mcx = r00 * lx + r01 * ly + r02 * lz
        local mcy = r10 * lx + r11 * ly + r12 * lz
        local mcz = r20 * lx + r21 * ly + r22 * lz
        local mw, mx, my, mz = Integrate.quat_mul(qw, qx, qy, qz,
            o.qw or 1, o.qx or 0, o.qy or 0, o.qz or 0)
        local m00, m01, m02, m10, m11, m12, m20, m21, m22 = Integrate.quat_to_matrix(mw, mx, my, mz)
        local hx, hy, hz = Shape.half_extents(o.view)
        local ex = mabs(m00) * hx + mabs(m01) * hy + mabs(m02) * hz
        local ey = mabs(m10) * hx + mabs(m11) * hy + mabs(m12) * hz
        local ez = mabs(m20) * hx + mabs(m21) * hy + mabs(m22) * hz
        if mcx - ex < lo_x then lo_x = mcx - ex end
        if mcx + ex > hi_x then hi_x = mcx + ex end
        if mcy - ey < lo_y then lo_y = mcy - ey end
        if mcy + ey > hi_y then hi_y = mcy + ey end
        if mcz - ez < lo_z then lo_z = mcz - ez end
        if mcz + ez > hi_z then hi_z = mcz + ez end
    end
    local ax = (mabs(lo_x) > mabs(hi_x)) and mabs(lo_x) or mabs(hi_x)
    local ay = (mabs(lo_y) > mabs(hi_y)) and mabs(lo_y) or mabs(hi_y)
    local az = (mabs(lo_z) > mabs(hi_z)) and mabs(lo_z) or mabs(hi_z)
    return ax, ay, az
end

-- ccd runs after position integration: snap to time-of-impact + kill into-surface velocity
-- no bounce, solver resolves the snapped contact next step
local CCD_MIN_FRAC = 0.5

-- conservative bound, cached on body, rotated aabb always >= this so it never misses a fast body
-- lets ccd skip quat->matrix for normal-speed bodies
local function ccd_min_half_bound(b)
    local cached = b._ccd_min_half
    if cached then return cached end
    local minh = math.huge
    local offs = b.local_offsets
    if offs and #offs > 0 then
        for i = 1, #offs do
            local o = offs[i]
            if o and o.view then
                local hx, hy, hz = Shape.half_extents(o.view)
                if hx < minh then minh = hx end
                if hy < minh then minh = hy end
                if hz < minh then minh = hz end
            end
        end
    else
        local asm = b.assembly
        local root = asm and asm.root_part
        if root then
            local hx, hy, hz = Shape.half_extents(root)
            minh = hx
            if hy < minh then minh = hy end
            if hz < minh then minh = hz end
        else
            minh = 2
        end
    end
    if minh == math.huge then minh = 2 end
    b._ccd_min_half = minh
    return minh
end

-- ccd honors CanCollide like the manifold filter, else non-collidables get clamped
local function ccd_body_collidable(b)
    local asm = b.assembly
    local mems = asm and asm.parts
    if not mems then return true end
    for i = 1, #mems do
        if mems[i].CanCollide ~= false then return true end
    end
    return false
end

function World:_ccd_static(dt)
    local active = self.active_bodies
    local count  = self.active_count
    local bp     = self.broadphase
    for i = 1, count do
        local b = active[i]
        if b.inv_mass > 0 and ccd_body_collidable(b) then
            local dx, dy, dz = b.vx * dt, b.vy * dt, b.vz * dt
            local d2 = dx * dx + dy * dy + dz * dz
            local pre = CCD_MIN_FRAC * ccd_min_half_bound(b)
            local handled,exact,exact_t,exact_nx,exact_ny,exact_nz
            if d2>1e-12 and d2>pre*pre then handled,exact,exact_t,exact_nx,exact_ny,exact_nz=Continuous.static(self,b)end
            if d2 > 1e-12 and d2 > pre * pre and not handled then
                local hbx, hby, hbz = body_aabb_half(b)
                local minh = hbx
                if hby < minh then minh = hby end
                if hbz < minh then minh = hbz end
                local thresh = CCD_MIN_FRAC * minh
                if d2 > thresh * thresh then
                    local c0x, c0y, c0z = b.com_x - dx, b.com_y - dy, b.com_z - dz
                    local member_filter
                    if exact then
                        c0x,c0y,c0z=exact.x,exact.y,exact.z;dx,dy,dz=exact.dx,exact.dy,exact.dz
                        member_filter=function(view)return not Continuous.supports_view(view)end
                    end
                    local t, nx, ny, nz =
                        bp:sweep_aabb_vs_static(c0x, c0y, c0z, hbx, hby, hbz, dx, dy, dz, b, self,member_filter)
                    if exact and exact_t<t then t,nx,ny,nz=exact_t,-exact_nx,-exact_ny,-exact_nz end
                    if t and t < 1 then
                        b.com_x = c0x + dx * t
                        b.com_y = c0y + dy * t
                        b.com_z = c0z + dz * t
                        local vn = b.vx * nx + b.vy * ny + b.vz * nz
                        if vn < 0 then
                            b.vx = b.vx - vn * nx
                            b.vy = b.vy - vn * ny
                            b.vz = b.vz - vn * nz
                        end
                        self.ccd_clamp_count = (self.ccd_clamp_count or 0) + 1
                    end
                end
            end
        end
    end
end

-- 1)velocity(gravity) 2)broadphase 3)narrowphase 4)solver 5)position+orientation, collision off skips 2-4
-- gravity before solve so a normal impulse cancels approach velocity same step (no sinking)
function World:fixed_step(dt)
    self._ccd_static_motions=nil
    self._ccd_collecting=self.config.collision_enabled and self.config.ccd_enabled
    if self.before_fixed_step then self.before_fixed_step(self, dt) end
    self._ccd_collecting=false
    self.step_index = self.step_index + 1

    Rope.wake(self, dt)
    -- 1. gravity
    Integrate.integrate_velocity(self.active_bodies, self.active_count, self.config.gravity, dt,
        self.config.max_linear_velocity)

    -- 1b. after gravity, before solver: a mover pushing into contact resolves this step
    if self.movers and self.movers:count() > 0 then
        local t0 = get_time()
        local active, applied = self.movers:apply(self, dt)
        self.mover_ms = (get_time() - t0) * 1000
        self.mover_active_count  = active
        self.mover_applied_count = applied
        -- a BodyPosition/force can pull a previously slack rope taut this step
        -- wake its endpoints before broadphase and effective masses are built
        -- exclude newly added gravity from the neighbour wake-speed test
        Rope.wake(self, dt, true)
    else
        self.mover_ms = 0
        self.mover_active_count  = 0
        self.mover_applied_count = 0
    end

    -- 2. broadphase
    if self.config.collision_enabled then
        local t0 = get_time()
        local bp = self.broadphase
        bp:reset_step_counters()

        if self.broadphase_statics_dirty then
            bp:reset_statics()
            local asms = self.assemblies
            for i = 1, #asms do
                local asm = asms[i]
                if asm.body and asm.body.is_static then
                    bp:insert_static(asm)
                end
            end
            self.broadphase_statics_dirty = false
        end

        local active = self.active_bodies
        local count  = self.active_count
        for i = 1, count do
            bp:upsert_dynamic(active[i])
        end

        -- only active bodies search, dedup table persistent + epoch-stamped, no per-substep alloc
        local pairs_out = self.broadphase_pairs
        local n = #pairs_out
        for i = n, 1, -1 do pairs_out[i] = nil end  -- fast clear
        local seen = self._broadphase_seen
        if not seen then seen = {}; self._broadphase_seen = seen end
        local epoch = self.step_index
        for i = 1, count do
            local body = active[i]
            -- an all-members-CanCollide=false body (NPC marker parts) can never
            -- produce a manifold (the cache rejects such views pairwise) and
            -- supports nothing -- skip its candidate scan, which costs hundreds of
            -- member AABB tests per body at per-part-singleton static density
            -- other bodies still find IT via the dynamic hash (upsert above), and
            -- raycasts still hit it, so behavior is identical
            local members = body.parts
            local can_contact = false
            for k = 1, body.part_count or (members and #members) or 0 do
                local v = members[k]
                if v and v.CanCollide ~= false then
                    can_contact = true
                    break
                end
            end
            if can_contact then
                bp:query_candidates(body, pairs_out, seen, epoch)
            end
        end
        -- epoch-stamp never removes stale keys, so drop the table periodically
        if epoch % 4096 == 0 then
            self._broadphase_seen = nil
        end

        self.static_proxy_count    = bp.static_proxy_count
        self.dynamic_proxy_count   = bp.dynamic_proxy_count
        self.dirty_proxy_count     = bp.dirty_proxy_count
        self.proxy_upsert_count    = bp.proxy_upsert_count
        self.candidate_check_count = bp.candidate_check_count
        self.broadphase_pair_count = bp.broadphase_pair_count

        local t1 = get_time()
        self.broadphase_ms = (t1 - t0) * 1000
    else
        -- collision off: zero counters
        self.broadphase_ms         = 0
        self.broadphase_pair_count = 0
        self.static_proxy_count    = 0
        self.dynamic_proxy_count   = 0
        self.dirty_proxy_count     = 0
        self.proxy_upsert_count    = 0
        self.candidate_check_count = 0
        local pairs_out = self.broadphase_pairs
        for i = #pairs_out, 1, -1 do pairs_out[i] = nil end
    end

    -- 3. narrowphase + manifolds
    if self.config.collision_enabled then
        local t0 = get_time()
        local cache = self.manifold_cache
        cache:update(self.broadphase_pairs, self.no_collision, self.part_to_assembly,
            self.step_index, self.collision_groups)
        -- prune = full pairs() walk (slow), tolerates 1 substep of latency
        if self.step_index % 2 == 0 then
            cache:prune(self.step_index, self.part_to_assembly)
        end
        self.narrowphase_ms        = (get_time() - t0) * 1000
        self.member_test_count     = cache.member_test_count or 0
        self.member_survivor_count = cache.member_survivor_count or 0
        self.member_node_visits = cache.member_node_visits or 0
        self.member_tree_builds = cache.member_tree_builds or 0
        self.member_tree_refits = cache.member_tree_refits or 0
        self.member_tree_fallbacks = cache.member_tree_fallbacks or 0
        self.contact_count         = cache.contact_count
        self.manifold_cache_count  = cache.cache_count
        self.manifold_active_count = cache.active_count
        self.manifold_pruned_count = cache.pruned_count
        self.can_collide_pair_rejects      = cache.can_collide_rejects or 0
        self.collision_group_pair_rejects  = cache.group_rejects or 0
        self.collision_filter_pair_rejects = cache.filter_rejects or 0
    else
        -- collision off: zero counters, drop cache
        self.narrowphase_ms        = 0
        self.contact_count         = 0
        self.manifold_cache_count  = 0
        self.manifold_active_count = 0
        self.manifold_pruned_count = 0
        self.can_collide_pair_rejects      = 0
        self.collision_group_pair_rejects  = 0
        self.collision_filter_pair_rejects = 0
        self.manifold_cache:clear()
    end

    -- 4. contacts and passive ropes share the existing velocity iterations
    if self.config.collision_enabled or #self.ropes > 0 then
        local t0 = get_time()
        local solved, viters, piters =
            self.solver:solve(self.manifold_cache, self.step_index, dt, self.config.gravity, self)
        self.solver_ms = (get_time() - t0) * 1000
        self.solver_contact_count       = solved
        self.solver_velocity_iterations = viters
        self.solver_position_iterations = piters
    else
        self.solver_ms = 0
        self.solver_contact_count       = 0
        self.solver_velocity_iterations = 0
        self.solver_position_iterations = 0
    end

    -- 5. integrate positions
    if self.config.collision_enabled and self.config.ccd_enabled then Continuous.capture(self) end
    Integrate.integrate_position(self.active_bodies, self.active_count, dt,
        self.config.max_linear_velocity, self.config.max_angular_velocity)

    if #self.ropes > 0 then self.solver:solve_rope_positions(self) end

    -- 5b. ccd: snap fast bodies that'd tunnel a static
    if self.config.collision_enabled and self.config.ccd_enabled then
        self:_ccd_static(dt)
        Continuous.resolve(self,dt)
    end

    -- 6. auto-sleep + any explicitly queued wake requests
    self:_update_sleep(dt)
    self:_drain_pending_wake()
    if self.after_fixed_step then self.after_fixed_step(self, dt) end
end

-- Controller activation volumes do not add contacts or impulses. Query only
-- the local sleeping hash, then reject conservative assembly proxy padding
-- against member bounds and the controller's collision group
function World:wake_in_bounds(lx,ly,lz,rx,ry,rz,group)
    local bp=self.broadphase
    if bp.sleeping_proxy_count==0 then return 0 end
    local out=self._wake_region_bodies or {};self._wake_region_bodies=out
    local count=bp:collect_sleepers(lx,ly,lz,rx,ry,rz,out)
    local woken=0
    for i=1,count do
        local body=out[i]
        for j=1,body.part_count or #body.parts do
            local p=body.parts[j]
            if p.CanCollide~=false and (not self.collision_groups
                or self.collision_groups:collidable(group or "Default",p.CollisionGroup or "Default")) then
                local cf=p.CFrameRef or p.CFrame
                local hx,hy,hz=Shape.half_extents(p)
                local ex=math.abs(cf.r00)*hx+math.abs(cf.r01)*hy+math.abs(cf.r02)*hz
                local ey=math.abs(cf.r10)*hx+math.abs(cf.r11)*hy+math.abs(cf.r12)*hz
                local ez=math.abs(cf.r20)*hx+math.abs(cf.r21)*hy+math.abs(cf.r22)*hz
                local x0,y0,z0,x1,y1,z1=cf.x-ex,cf.y-ey,cf.z-ez,cf.x+ex,cf.y+ey,cf.z+ez
                if x1>=lx and x0<=rx and y1>=ly and y0<=ry and z1>=lz and z0<=rz then
                    self:wake_body(body);woken=woken+1;break
                end
            end
        end
        out[i]=nil
    end
    return woken
end

-- an equality component may contain one momentarily slow member while other
-- members still move above the ordinary sleep thresholds. Sleeping that one
-- member discards its momentum and turns an internal constraint into an anchor
local function equality_sleep_root(parents,body)
    local root=body
    while parents[root]~=root do root=parents[root] end
    while body~=root do
        local next_body=parents[body];parents[body]=root;body=next_body
    end
    return root
end

local function equality_sleep_live(world,body)
    return body and body.world==world and body._body_world_index
        and world.bodies[body._body_world_index]==body
end

function World:_equality_sleep_activity(lin2,ang2)
    local parents,activity
    for _,row in ipairs(self.ropes) do
        local a,b=row.ba,row.bb
        if (row.kind=="rod" or row.length==0) and a~=b
            and equality_sleep_live(self,a) and equality_sleep_live(self,b) then
            if not a.is_static or not b.is_static then
                if not parents then
                    parents=self._equality_sleep_parents or {}
                    activity=self._equality_sleep_active or {}
                    self._equality_sleep_parents,self._equality_sleep_active=parents,activity
                end
                if not a.is_static and not parents[a] then parents[a]=a end
                if not b.is_static and not parents[b] then parents[b]=b end
                -- a common static anchor does not connect independent dynamics
                if not a.is_static and not b.is_static then
                    local ra,rb=equality_sleep_root(parents,a),equality_sleep_root(parents,b)
                    if ra~=rb then parents[rb]=ra end
                end
            end
        end
    end
    if not parents then return end
    for body in pairs(parents) do parents[body]=equality_sleep_root(parents,body) end
    for body,root in pairs(parents) do
        local v2=body.vx*body.vx+body.vy*body.vy+body.vz*body.vz
        local w2=body.wx*body.wx+body.wy*body.wy+body.wz*body.wz
        -- match the existing strict-under-threshold eligibility exactly
        if not (v2<lin2 and w2<ang2) then activity[root]=true end
    end
    return parents,activity
end

-- iterates backwards so swap-remove cant skip an entry
function World:_update_sleep(dt)
    self.sleep_candidate_count = 0
    if not self.config.sleeping_enabled then
        return
    end
    local lin2 = self.config.sleep_linear_threshold
    lin2 = lin2 * lin2
    local ang2 = self.config.sleep_angular_threshold
    ang2 = ang2 * ang2
    local sleep_time = self.config.sleep_time
    local deep_time = self.config.deep_sleep_time or 0
    local deep_tol2 = (self.config.deep_sleep_tolerance or 0) ^ 2
    local active = self.active_bodies
    local equality_parents,equality_activity=self:_equality_sleep_activity(lin2,ang2)
    local candidates = 0
    for i = self.active_count, 1, -1 do
        local b = active[i]
        if b then
            local component=equality_parents and equality_parents[b]
            if component and equality_activity[component] then
                b.sleep_timer,b.deep_timer=0,0
                b.deep_ref_x,b.deep_ref_qw=nil,nil
                b.deep_slept=false
            else
            local v2 = b.vx * b.vx + b.vy * b.vy + b.vz * b.vz
            local w2 = b.wx * b.wx + b.wy * b.wy + b.wz * b.wz
            local slept = false
            if v2 < lin2 and w2 < ang2 then
                b.sleep_timer = b.sleep_timer + dt
                candidates = candidates + 1
                if b.sleep_timer >= sleep_time then
                    b.deep_slept = false -- slept on velocity, not deep-sleep
                    self:sleep_body(b)
                    self:queue_sleep_pose_publication(b)
                    self.auto_sleep_count = self.auto_sleep_count + 1
                    slept = true
                end
            else
                b.sleep_timer = 0
            end
            -- compare the whole pose, not just the COM: a spinning brick or
            -- constrained limb can rotate continuously about a stationary centre
            if not slept and deep_time > 0 then
                local rx = b.deep_ref_x
                if rx == nil or b.deep_ref_qw == nil then
                    b.deep_ref_x, b.deep_ref_y, b.deep_ref_z = b.com_x, b.com_y, b.com_z
                    b.deep_ref_qw, b.deep_ref_qx, b.deep_ref_qy, b.deep_ref_qz = b.qw,b.qx,b.qy,b.qz
                    b.deep_timer = 0
                else
                    local dx, dy, dz = b.com_x - rx, b.com_y - b.deep_ref_y, b.com_z - b.deep_ref_z
                    local dot = b.qw*b.deep_ref_qw+b.qx*b.deep_ref_qx+b.qy*b.deep_ref_qy+b.qz*b.deep_ref_qz
                    local radius = b:bounding_radius()
                    local rotation2 = 4*radius*radius*math.max(0,1-dot*dot)
                    if dx * dx + dy * dy + dz * dz + rotation2 > deep_tol2 then
                        b.deep_ref_x, b.deep_ref_y, b.deep_ref_z = b.com_x, b.com_y, b.com_z
                        b.deep_ref_qw, b.deep_ref_qx, b.deep_ref_qy, b.deep_ref_qz = b.qw,b.qx,b.qy,b.qz
                        b.deep_timer = 0
                    else
                        b.deep_timer = (b.deep_timer or 0) + dt
                        if b.deep_timer >= deep_time then
                            b.deep_slept = true -- diagnostic, normal contact activation still applies
                            self:sleep_body(b)
                            self:queue_sleep_pose_publication(b)
                            self.auto_sleep_count = self.auto_sleep_count + 1
                            self.deep_sleep_count = (self.deep_sleep_count or 0) + 1
                        end
                    end
                end
            end
            end -- unchanged quiet-component sleep logic
        end
    end
    self.sleep_candidate_count = candidates
    if equality_parents then
        for body in pairs(equality_parents) do equality_parents[body]=nil end
        for root in pairs(equality_activity) do equality_activity[root]=nil end
    end
end

function World:_drain_pending_wake()
    local n = self._pending_wake_count
    if n == 0 then
        return
    end
    local q = self._pending_wake
    for i = 1, n do
        local b = q[i]
        if b then
            b._wake_queued = nil
            self:wake_body(b, true)
        end
        q[i] = nil
    end
    self._pending_wake_count = 0
end

-- accumulator shell, zero-cost when disabled
function World:step(dt)
    -- raw World clients may not have a renderer, retire the previous step too
    self:clear_sleep_pose_publications()
    local accounting = self.time_accounting
    self.last_substeps, self.last_idle_substeps, self.substeps_completed = 0, 0, 0
    dt = tonumber(dt)
    if not dt or dt ~= dt or dt == math.huge or dt == -math.huge or dt < 0 then
        accounting.invalid_inputs = accounting.invalid_inputs + 1
        return 0
    end
    accounting.input_seconds = accounting.input_seconds + dt
    if not self.config.enabled then
        accounting.disabled_seconds = accounting.disabled_seconds + dt
        return 0
    end
    local admitted = math.min(dt, self.config.max_frame_dt)
    accounting.frame_clamp_seconds = accounting.frame_clamp_seconds + dt - admitted
    accounting.admitted_seconds = accounting.admitted_seconds + admitted
    dt = admitted
    if dt <= 0 then return 0 end

    -- wake targets before active-set reconcile so a mover-driven body enters active this step
    -- gate on body sigs too, not just count()>0: last-mover removal must still wake (hover platform falling)
    local movers = self.movers
    if movers and (movers:count() > 0
            or (movers._body_sigs and next(movers._body_sigs) ~= nil)) then
        movers:wake_targets(self)
    end

    -- only on external sleep-state flip (topology rebuild/api wake), steady state skips this
    if self.active_dirty then
        self:refresh_active()
    end

    local fixed_dt     = self.config.fixed_dt
    local max_substeps = self.config.max_substeps
    local budget_ms    = self.config.budget_ms

    self.accumulator = self.accumulator + dt
    -- one picosecond guards accumulated floating-point boundary roundoff only
    -- retain a possible tiny negative remainder so accounting stays conservative
    local step_epsilon = 1e-12
    local available = math.floor((self.accumulator + step_epsilon) / fixed_dt)
    local capped = math.max(0, available - max_substeps) * fixed_dt
    if capped > 0 then
        self.accumulator = self.accumulator - capped
        accounting.step_cap_seconds = accounting.step_cap_seconds + capped
        self.accumulator_dropped_seconds = self.accumulator_dropped_seconds + capped
        self.accumulator_dropped_count = self.accumulator_dropped_count + 1
    end
    self.substeps_attempted = math.min(available, max_substeps)

    if self.substeps_attempted > 0 then Rope.wake(self, fixed_dt) end
    -- idle fast path: all asleep, drain the accumulator w/o the substep loop
    -- wake sources must set state BEFORE this check, else a fake "missed substeps" backlog
    self.last_idle_substeps = 0
    if self.active_count == 0
        and not self.before_fixed_step
        and self._pending_wake_count == 0
        and not self.active_dirty
        and not self.collision_dirty
        and not self.broadphase_statics_dirty then
        local idle_substeps = self.substeps_attempted
        if idle_substeps > 0 then
            self.accumulator = self.accumulator - idle_substeps * fixed_dt
            accounting.idle_steps = accounting.idle_steps + idle_substeps
            accounting.simulated_seconds = accounting.simulated_seconds + idle_substeps * fixed_dt
            -- rotatev keys off step_index*fixed_dt: skipped substeps must still advance it or it freezes
            self.step_index = (self.step_index or 0) + idle_substeps
            self.step_count = self.step_count + idle_substeps
        end
        self.idle_fast_path_count = (self.idle_fast_path_count or 0) + 1
        self.idle_skipped_substeps = (self.idle_skipped_substeps or 0) + idle_substeps
        self.last_idle_substeps = idle_substeps
        self.step_wall_ms = 0
        self.substeps_completed = 0
        self.last_substeps = 0
        return 0
    end

    local t_start = (budget_ms > 0) and get_time() or 0
    local substeps = 0
    local budget_hit = false
    while self.accumulator + step_epsilon >= fixed_dt and substeps < max_substeps do
        self:fixed_step(fixed_dt)
        accounting.executed_steps = accounting.executed_steps + 1
        accounting.simulated_seconds = accounting.simulated_seconds + fixed_dt
        -- Opt-in aggregate of existing per-step counters, including every substep
        local totals = self._profile_totals
        if totals then
            for _, key in ipairs(PROFILE_STEP_COUNTERS) do
                totals[key] = (totals[key] or 0) + (self[key] or 0)
            end
        end
        self.accumulator = self.accumulator - fixed_dt
        substeps = substeps + 1
        -- checked after a completed substep, so at least one always runs
        if budget_ms > 0 and (get_time() - t_start) * 1000 >= budget_ms then
            budget_hit = true
            break
        end
    end

    self.step_wall_ms       = (budget_ms > 0) and ((get_time() - t_start) * 1000) or 0
    self.substeps_completed = substeps
    if budget_hit then
        self.budget_exceeded_count = self.budget_exceeded_count + 1
    end
    -- drop leftover whole substeps: slow frame slow-mos instead of spiraling, sub-dt remainder kept for smoothness
    local dropped = math.max(0, math.floor((self.accumulator + step_epsilon) / fixed_dt)) * fixed_dt
    if dropped > 0 then
        self.accumulator_dropped_seconds = self.accumulator_dropped_seconds + dropped
        -- preserve the legacy counter's frame unit when both limits fired
        if capped == 0 then self.accumulator_dropped_count = self.accumulator_dropped_count + 1 end
        accounting.budget_seconds = accounting.budget_seconds + dropped
        self.accumulator = self.accumulator - dropped
    end

    self.step_count    = self.step_count + substeps
    self.last_substeps = substeps
    -- clear here to restore the idle fast path, else one CanCollide toggle kills it for the session
    if substeps > 0 and self.collision_dirty then
        self.collision_dirty = false
    end
    return substeps
end

function World:reset()
    for _,body in ipairs(self.bodies) do ManifoldCache.release_member_ranges(body) end
    self:clear_sleep_pose_publications()
    self.ropes = {}
    self._rope_bound_revision = nil
    self._rope_topology_revision = (self._rope_topology_revision or 0) + 1
    self.time_accounting.reset_seconds = self.time_accounting.reset_seconds + self.accumulator
    self.time_accounting.reset_events = self.time_accounting.reset_events + 1
    self.accumulator   = 0
    self.step_count    = 0
    self.step_index    = 0
    self.last_substeps = 0

    self.solver_ms            = 0
    self.solver_contact_count = 0
    self.solver_velocity_iterations = 0
    self.solver_position_iterations = 0
    self.mover_ms             = 0
    self.mover_active_count   = 0
    self.mover_applied_count  = 0
    if self.movers then self.movers:clear() end
    self.broadphase_ms        = 0
    self.narrowphase_ms       = 0
    self.broadphase_pair_count = 0
    self.contact_count         = 0

    self.static_proxy_count    = 0
    self.dynamic_proxy_count   = 0
    self.dirty_proxy_count     = 0
    self.proxy_upsert_count    = 0
    self.candidate_check_count = 0

    self.manifold_cache_count  = 0
    self.manifold_active_count = 0
    self.manifold_pruned_count = 0

    self.collision_filter_pair_rejects = 0
    self.can_collide_pair_rejects      = 0
    self.collision_group_pair_rejects  = 0
    self.contact_cache_clears_from_filter_change = 0
    if self.collision_groups then self.collision_groups:reset() end
    self.no_collision_runtime = {}

    self.transform_updates_from_physics   = 0
    self.full_render_rebuilds_from_physics = 0

    self.assembly_rebuild_count         = 0
    self.topology_dirty_count           = 0
    self.rigid_joint_count              = 0
    self.unsupported_joint_count        = 0
    self.largest_assembly_part_count    = 0
    self.anchored_static_assembly_count = 0

    self.collision_dirty          = false
    self.active_count             = 0
    self.active_dirty             = true
    self.idle_fast_path_count     = 0
    self.idle_skipped_substeps    = 0
    self._pending_wake_count      = 0
    self.sleep_candidate_count       = 0
    self.auto_sleep_count            = 0
    self.wake_event_count            = 0
    self.wake_propagation_count      = 0
    self.sleeping_proxy_count        = 0
    self.step_wall_ms                = 0
    self.substeps_attempted          = 0
    self.substeps_completed          = 0
    self.budget_exceeded_count       = 0
    self.accumulator_dropped_count   = 0
    self.accumulator_dropped_seconds = 0
    self.ccd_clamp_count             = 0
    self.broadphase_statics_dirty = true
    self.broadphase               = Broadphase.new()
    self.broadphase_pairs         = {}
    self.manifold_cache:reset()
end

return World
