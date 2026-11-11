-- Boundary-only supplement to profile.lua. Reads retained runtime evidence;
-- never resolves/downloads an asset or claims cache presence proves full coverage.
local M = {}
local json = require("engine/services/oss/menori/modules/libs/json")
local function known(v) if v == nil then return "UNKNOWN" end; return v end
local function nonempty(v) return type(v) == "string" and v ~= "" end
local function hash(bytes)
    return love.data.encode("string", "hex", love.data.hash("sha256", bytes))
end
M.encode, M.decode = json.encode, json.decode

-- Fixed ordinary-run scope, enumerated again at the boundary so omitted/new
-- files cannot pass merely because a manifest exists. This does not resolve assets.
function M.source_paths()
    local paths = {"main.lua", "conf.lua"}
    local function walk(dir)
        for _, name in ipairs(love.filesystem.getDirectoryItems(dir)) do
            local p = dir .. "/" .. name
            local info = love.filesystem.getInfo(p)
            if info and info.type == "directory" then walk(p)
            elseif p:match("%.lua$") or p:match("%.glsl$") then paths[#paths+1] = p end
        end
    end
    walk("engine")
    table.sort(paths); return paths
end

local function read_file(path)
    local f = io.open(path, "rb")
    if f then local b=f:read("*a");f:close();return b end
end

function M.verify_identity(source, map_path, map_hash, assets, dependencies)
    dependencies = dependencies or {read=read_file, paths=M.source_paths}
    local issues, checked = {}, {}
    local function fail(code, path, detail)
        issues[#issues+1] = {code=code, path=path or "UNKNOWN", detail=detail}
    end
    local function check(row, kind)
        if type(row)~="table" or not nonempty(row.path) or not nonempty(row.sha256) then
            fail("identity_dependency", kind, "path and SHA256 required");return
        end
        local bytes=dependencies.read(row.path)
        if not bytes then fail("identity_missing_file",row.path,kind)
        elseif hash(bytes)~=row.sha256:lower() then fail("identity_stale_file",row.path,kind)
        else checked[#checked+1]={path=row.path,sha256=row.sha256:lower(),kind=kind} end
    end
    if type(source)~="table" or source.schema_version~=2 or source.scope~="rbx-ordinary-inputs-v1" then
        fail("identity_scope", "source manifest", "requires v2 RBX ordinary source/runtime/map manifest")
    else
        local present={}
        for _,row in ipairs(source.files or {}) do
            if present[row.path] then fail("identity_duplicate",row.path,"duplicate source entry") end
            present[row.path]=true;check(row,"source")
        end
        for _,path in ipairs(dependencies.paths()) do
            if not present[path] then fail("identity_scope_omission",path,"current source file absent from manifest") end
        end
        if not source.map or source.map.path~=map_path or source.map.sha256~=map_hash then
            fail("identity_map",map_path,"manifest must identify the actual committed map")
        else check(source.map,"map") end
        local runtime=source.runtime or {};local modules={};local components={}
        for _,m in ipairs(runtime.modules or {}) do modules[(m.name or ""):lower()]=(m.path or ""):gsub("\\","/"):lower() end
        for _,c in ipairs(runtime.components or {}) do
            components[(c.file or ""):lower()]=true
            local path=(runtime.directory or "").."/"..(c.file or "")
            check({path=path,sha256=c.sha256},"runtime")
            if modules[(c.file or ""):lower()] and modules[c.file:lower()]~=path:gsub("\\","/"):lower() then
                fail("identity_runtime_module",path,"loaded module path differs")
            end
        end
        for _,name in ipairs({"lovec.exe","love.dll","lua51.dll","sdl2.dll"}) do
            if not components[name] or not modules[name] then fail("identity_runtime_dependency",name,"component hash and actual loaded-module path required") end
        end
    end
    -- Missing references are identified inputs, not complete render resources.
    -- Validate every locally resolved file independently; embedded geometry is
    -- identified by the committed map and its per-owner byte hashes.
    local resources={}
    for _,r in ipairs(assets and assets.resources or {}) do
        resources[#resources+1]={asset=r.asset,role=r.role,state=r.state,required=r.required,affected=r.affected,
            resolved_path=r.resolved_path,sha256=r.sha256}
        if r.required~=false and r.state=="resolved" then
            if nonempty(r.resolved_path) and r.resolved_path~="UNKNOWN" then
                local bytes=love.filesystem.read(r.resolved_path)
                if not bytes or not nonempty(r.sha256) or hash(bytes)~=r.sha256 then
                    fail("identity_resource",r.resolved_path,"retained source bytes absent or changed")
                end
            elseif not r.embedded_in_map then
                fail("identity_resource_dependency",r.asset,"resolved input lacks retained file/embedded provenance")
            end
        end
    end
    return {verified=#issues==0,status=#issues==0 and "VERIFIED" or "UNVERIFIED",issues=issues,files=checked,
        resources=resources,scope="declared current source, actual runtime modules, committed map and retained resource bytes; not asset completeness or rendering correctness"}
end

-- Mirrors _draw_single_celestial's early-outs only; no resource creation.
-- This reports requirements for the recorded lighting state, not all clock times.
function M.celestial_required(sky, kind)
    if sky[kind .. "_renderable"] == false then return false, "celestial property disabled or absent" end
    local direction = sky[kind .. "_direction"]
    if direction and direction[2] and direction[2] < -0.30 then return false, "below renderer horizon cutoff at recorded clock time" end
    local size = sky[kind .. "_angular_size"]
    if size and size <= 0 then return false, "zero angular size" end
    local night = sky.night_factor
    if night then
        local alpha = kind == "sun" and (1 - night) or (night * 0.95)
        if alpha <= 0.02 then return false, "celestial opacity below submission threshold" end
    end
    return true
end

function M.classify(resources, coverage)
    local counts = { resolved = 0, pending = 0, missing = 0, failed = 0, unknown = 0, fallback = 0, ignored = 0 }
    for _, r in ipairs(resources) do
        local state = r.required == false and "ignored" or r.state
        if not counts[state] then state = "unknown" end
        counts[state] = counts[state] + 1
    end
    local status = "COMPLETE"
    if counts.failed + counts.missing + counts.fallback > 0 then status = "INCOMPLETE"
    elseif counts.pending > 0 then status = "PENDING"
    elseif counts.unknown > 0 or coverage ~= true then status = "UNKNOWN" end
    return { status = status, counts = counts, coverage_complete = coverage == true, resources = resources }
end

-- Gate the bounded workload without equating diagnostic permission with acceptance.
function M.allow_measurement(assets)
    if assets.status == "COMPLETE" and assets.coverage_complete then return true end
    local c = assets.counts
    if not assets.coverage_complete or c.missing ~= 1 or c.failed ~= 0 or c.pending ~= 0 or c.unknown ~= 0 or (c.fallback or 0) ~= 0 then return false end
    for _, r in ipairs(assets.resources) do
        if r.required and r.state ~= "resolved" and r.role ~= "celestial:sun" then return false end
    end
    return true -- only the identified sun fallback, still INCOMPLETE
end

function M.validate(record)
    local reasons = {}
    local function require_value(ok, why) if not ok then reasons[#reasons + 1] = why end end
    local requested, effective = record.requested, record.effective
    for _, key in ipairs({ "project", "map", "physics", "remote_assets", "remote_meshes" }) do
        require_value(effective[key] ~= nil and effective[key] ~= "UNKNOWN"
            and effective[key] == requested[key], "configuration mismatch: " .. key)
    end
    require_value(record.commit.success == true and record.commit.done == true
        and record.commit.active == false and record.commit.map == effective.map, "map commit unverified")
    require_value(record.rendered_frames > 0, "no profiled rendered frames")
    require_value(record.visual_assets.status == "COMPLETE", "visual assets " .. record.visual_assets.status)
    record.identity = M.verify_identity(record.source, effective.map, record.map_sha256, record.visual_assets, record._identity_dependencies)
    record._identity_dependencies=nil
    require_value(record.identity.verified, "source identity unverified")
    local blockers={}
    for _,issue in ipairs(record.identity.issues) do
        blockers[#blockers+1]=issue
        reasons[#reasons+1]=issue.code..": "..issue.path.." ("..tostring(issue.detail)..")"
    end
    for _,r in ipairs(record.visual_assets.resources or {}) do
        if r.required~=false and r.state~="resolved" and r.state~="ignored" then
            blockers[#blockers+1]={code="required_resource_"..tostring(r.state),asset=r.asset,role=r.role,owners=r.affected,detail=r.reason}
            reasons[#reasons+1]="required resource "..tostring(r.state)..": "..tostring(r.asset).." ["..tostring(r.role).."]"
        end
    end
    for _,gap in ipairs(record.visual_assets.coverage_details or {}) do blockers[#blockers+1]=gap end
    for _,gap in ipairs(record.visual_assets.coverage_gaps or {}) do reasons[#reasons+1]="unverified route: "..gap end
    require_value(nonempty(record.run_id) and record.run_id ~= "UNKNOWN" and nonempty(record.timestamp_utc), "run identity incomplete")
    require_value(nonempty(record.map_sha256) and record.map_sha256 ~= "UNKNOWN", "map hash unavailable")
    require_value(record.completion.status == "profile_complete", "profile incomplete")
    require_value(record.graphics.device ~= "UNKNOWN" and record.graphics.api ~= "UNKNOWN", "graphics identity incomplete")
    local settings = record.settings or {}
    require_value(type(settings.resolution) == "table" and type(settings.resolution.width) == "number"
        and type(settings.resolution.height) == "number" and type(settings.vsync) == "number"
        and type(settings.frame_limiter_seconds) == "number", "effective display settings incomplete")
    record.application_loaded = record.commit.success == true and record.commit.done == true
        and record.commit.active == false and record.commit.map == effective.map and record.rendered_frames > 0
    record.baseline_eligible = #reasons == 0
    record.ineligible_reasons = reasons
    record.eligibility_blockers = blockers
    record.resource_completeness = record.visual_assets.status=="COMPLETE" and record.visual_assets.coverage_complete==true
    record.eligibility_scope = "configuration, identified inputs and resource coverage only; HDR equality, appearance policy and performance acceptance are not assessed"
    return record
end

-- Boundary inspection of the existing local-first selection in _resolve_part_mesh.
-- Remote-enabled selection is deliberately unproven here. No resolver calls.
function M.retained_geometry(core, part, key, role)
    if core.allow_remote_mesh_fetch == true then
        return nil, "unknown", "remote geometry selection is outside this local boundary"
    end
    local local_mesh = key and core._mesh_cache and core._mesh_cache[key]
    local embedded = part._embedded_mesh_cache
    local mesh = role == "csg_mesh" and type(local_mesh) == "table" and local_mesh
        or (type(embedded) == "table" and embedded) or local_mesh
    if type(mesh) == "table" then
        if mesh.source_kind == "csg_physics" then
            return mesh, "fallback", "collision geometry is not authored render geometry"
        elseif mesh.source_kind == "csg_child_parts" or mesh.csg_approximated then
            return mesh, "fallback", "approximated CSG/child composition is not verified authored render geometry"
        elseif mesh.source_kind == "mesh" or mesh.source_kind == "csg_mesh" then
            return mesh, "resolved", "retained decoded authored geometry on local selection route"
        end
        return mesh, "unknown", "decoded geometry lacks a verified render-source kind"
    end
    if key and core._asset_path_cache and core._asset_path_cache[key] == false then
        return nil, "missing", "visual mesh has no local resolver result; fetching disabled"
    end
    return nil, "unknown", "selected decoded geometry not retained at inspected boundary"
end

function M.assets(core, stats)
    local resources, by_key, used_materials = {}, {}, {}
    local coverage_gaps, categories = {}, {}
    local coverage_details = {}
    local material_matches, part_total, retained_layers = {}, 0, 0
    local content_hashes, geometry_routes, gui_referents = {}, {}, {}
    local function add(id, role, state, reason, part, required)
        id = nonempty(id) and id or "UNKNOWN"
        local key = role .. "|" .. id .. "|" .. state
        local row = by_key[key]
        if not row then
            row = { asset = id, role = role, state = state, reason = reason,
                required = required ~= false, affected = {} }
            by_key[key], resources[#resources + 1] = row, row
        end
        if part then
            local referent=part.Referent or part.referent or part._map_referent
            local instances=core._datamodel and core._datamodel._instance_by_referent
            local owner=instances and instances[referent] or part
            row.affected[#row.affected + 1] = { name = known(part.Name or part.name),
                referent = known(referent), runtime_id = known(part._id),
                path = type(owner.GetFullName)=="function" and owner:GetFullName() or nil }
        end
        return row
    end
    local memo = core._renderer_asset_cache_key_memo or {}
    local function asset_key(id, role)
        local entry = memo[role] and memo[role][id]
        return entry and entry.key
    end
    local function texture(id, role, part)
        if not nonempty(id) then return end
        local key = asset_key(id, "texture")
        local resolved, missing, pending, retained_path = false, false, false, nil
        if key then
            for sampler, image in pairs(core._texture_cache or {}) do
                if sampler:sub(1, #key + 1) == key .. "|" then
                    if core._texture_cache_missing and core._texture_cache_missing[sampler] then missing = true
                    elseif image and core._texture_cache_resolved and core._texture_cache_resolved[sampler] then
                        resolved = true;retained_path=core._texture_cache_resolved[sampler]
                    end
                    local manager = core._remote_texture_manager
                    local handle = manager and manager.sampler_handles[sampler]
                    if handle and handle.pending then pending = true end
                end
            end
        end
        -- Different sampler roles can differ. Never let one successful variant
        -- turn an unresolved variant into an authored-success claim.
        local absent = key and core._asset_path_cache and core._asset_path_cache[key] == false
        local state = pending and "pending" or (missing and (absent and "missing" or "failed") or (resolved and "resolved" or "unknown"))
        local row = add(id, role, state, state == "resolved" and "retained decoded GPU sampler and source path"
            or (state == "missing" and "local resolver returned no asset; placeholder/procedural fallback is not authored success; fetching disabled"
                or state == "failed" and "retained negative sampler despite path resolution; decode/upload failure"
                or "no conclusive usable sampler for this dependency"), part)
        if state == "resolved" then
            local path = core._asset_path_cache and core._asset_path_cache[key]
            if type(path)~="string" then path=retained_path end
            row.resolved_path = known(path)
            if type(path) == "string" then
                if not content_hashes[path] then
                    local bytes = love.filesystem.read(path)
                    content_hashes[path] = bytes and hash(bytes) or "UNKNOWN"
                end
                row.sha256 = content_hashes[path]
            end
        end
    end
    for _, part in ipairs(core.parts or {}) do
        if (tonumber(part.Transparency) or 0) < 1 or #(part.FaceTextures or {}) > 0 then
            part_total = part_total + 1
            used_materials[tonumber(part.Material) or tostring(part.Material)] = part
            if core._part_has_renderable_mesh_source(part) then
                local id = core._get_default_part_mesh_asset_path(part) or part.MeshId
                local role = (part.ClassName == "UnionOperation" or part.ClassName == "NegateOperation") and "csg_mesh" or "mesh"
                local key = id and asset_key(id, role)
                local mesh, state, reason = M.retained_geometry(core, part, key, role)
                local kind = type(mesh) == "table" and mesh.source_kind or "UNKNOWN"
                geometry_routes[kind] = (geometry_routes[kind] or 0) + 1
                local row = add(id or "embedded", role, state, reason, part)
                local source_path=key and core._asset_path_cache and core._asset_path_cache[key]
                if state=="resolved" and type(source_path)=="string" then
                    local bytes=love.filesystem.read(source_path)
                    row.resolved_path=source_path;row.sha256=bytes and hash(bytes) or "UNKNOWN"
                elseif state=="resolved" and type(mesh)=="table" and mesh==part._embedded_mesh_cache then row.embedded_in_map=true end
                row.source_kinds = row.source_kinds or {}
                row.source_kinds[kind] = true
                -- Keep deduplication but identify ambiguous embedded payloads by
                -- affected instance and ordered byte hashes, never exporting bytes.
                if not nonempty(id) then
                    local affected = row.affected[#row.affected]
                    affected.embedded_sha256 = {}
                    local payloads = part.EmbeddedMeshDataCandidates or {part.EmbeddedMeshData}
                    for _, bytes in ipairs(payloads) do
                        if type(bytes) == "string" then
                            content_hashes[bytes] = content_hashes[bytes] or hash(bytes)
                            affected.embedded_sha256[#affected.embedded_sha256+1] = content_hashes[bytes]
                        end
                    end
                end
            elseif nonempty(part.MeshId) then
                add(part.MeshId, "mesh", "ignored", "inactive mesh property for effective geometry owner", part, false)
            end
            local selected_texture = nonempty(part.TextureContent) and part.TextureContent or part.TextureId
            texture(selected_texture, "part_texture", part)
            if nonempty(part.TextureContent) and nonempty(part.TextureId) and part.TextureContent ~= part.TextureId then
                add(part.TextureId, "part_texture", "ignored", "TextureContent supersedes TextureId", part, false)
            end
            if part._ft_cache == nil and core._part_has_face_layers and core._part_has_face_layers(part) then
                coverage_gaps[#coverage_gaps + 1] = "effective face layers not retained for part " .. tostring(part._id)
            end
            for _, face in ipairs(part._ft_cache or part.FaceTextures or {}) do
                if (tonumber(face.transparency) or 0) < 1 then
                    retained_layers = retained_layers + 1
                    texture(face.texture or face.Texture or face.asset_path, face.source_kind == "SurfaceOverlay" and "generated_diffuse" or "authored_face_texture", part)
                    texture(face.normal_texture, "generated_normal", part)
                end
            end
        end
    end
    for _, material in pairs(core._material_cache or {}) do
        local part = used_materials[material.token] or used_materials[material.canonical_token]
        if part then
            material_matches[tonumber(part.Material) or tostring(part.Material)] = true
            categories["material:" .. material.name] = { folder = material.folder, has_maps = material.has_texture_maps == true }
            if material.folder ~= "Flat" and material.has_color_map ~= true then
                add(material.name, "material_color", "missing", "effective material family uses fallback; required color source unavailable", part)
            end
            for _, channel in ipairs({ "color", "normal", "roughness", "metalness" }) do
                local image = material[channel .. "_texture"]
                local info = core._texture_sampler_debug_by_texture and core._texture_sampler_debug_by_texture[image]
                if info then texture(info.asset_path, "material_" .. channel, part)
                elseif material["has_" .. channel .. "_map"] then
                    add(material.name .. ":" .. channel, "material_map", "unknown", "bound channel lacks authored-source metadata", part)
                end
            end
        end
    end
    for face, state in pairs(core._sky_face_status or {}) do
        local id = (core._sky_face_assets or {})[face]
        if state == "blank" then add(id or face, "sky", "ignored", "legitimately blank authored sky face", nil, false)
        else texture(id, "sky:" .. face) end
    end
    local sky = core.get_sky_diagnostics and core:get_sky_diagnostics() or {}
    local sky_owner
    local lighting = core._datamodel and core._datamodel:FindService("Lighting")
    if lighting then
        for _, child in ipairs(lighting:GetChildren()) do
            if child.ClassName == "Sky" then sky_owner = child; break end
        end
    end
    for kind, entry in pairs(core._celestial_texture_entries or {}) do
        local required, reason = M.celestial_required(sky, kind)
        if required then texture(entry.asset_path, "celestial:" .. kind, sky_owner)
        else add(entry.asset_path, "celestial:" .. kind, "ignored", reason, sky_owner, false) end
    end
    local function nodes(list, enabled)
        for _, node in ipairs(list or {}) do
            local visible = enabled and node.visible ~= false
            if node.class_name == "ImageLabel" or node.class_name == "ImageButton" then
                if node.referent ~= nil then gui_referents[tostring(node.referent)] = true end
                if visible and (tonumber(node.image_transparency) or 0) < 1 and nonempty(node.image) then
                    texture(node.image, "gui_image", node)
                else
                    add(node.image, "gui_image", "ignored", "effective GUI ancestry/image is disabled, transparent or blank", node, false)
                end
            end
            nodes(node.children, visible)
        end
    end
    for _, entry in ipairs(core._surface_gui_entries or {}) do
        local gui = entry.surface_gui
        if gui then nodes(gui.nodes, gui.enabled ~= false) end
    end
    -- Aggregate submission diagnostics prove missing geometry even when a
    -- per-instance cached decoder result is unavailable.
    for _, name in ipairs({ "missing_mesh_count", "missing_union_mesh_count", "missing_face_texture_count" }) do
        if (tonumber(stats[name]) or 0) > 0 then
            add(name, "scene_submission", "missing", tostring(stats[name]) .. " reported by production submission diagnostics")
        end
    end
    table.sort(resources, function(a, b) return a.role .. a.asset .. a.state < b.role .. b.asset .. b.state end)
    for token in pairs(used_materials) do
        if not material_matches[token] then coverage_gaps[#coverage_gaps + 1] = "material descriptor unavailable: " .. tostring(token) end
    end
    local classes, uninspected_gui = {}, {}
    if core._datamodel and core._datamodel.GetDescendants then
        for _, instance in ipairs(core._datamodel:GetDescendants()) do
            local class = instance.ClassName
            classes[class] = (classes[class] or 0) + 1
            if class=="SpecialMesh" or class=="MeshPart" or class=="UnionOperation" or class=="SurfaceAppearance"
                or class=="MaterialVariant" or class=="ViewportFrame" or class=="VideoFrame" or class=="Beam" or class=="Trail" then
                coverage_details[#coverage_details+1]={code="unverified_source_route",route=class,
                    owner={name=instance.Name,referent=instance.Referent,path=type(instance.GetFullName)=="function" and instance:GetFullName() or nil},
                    mesh_type=tostring(instance.MeshType),mesh_id=tostring(instance.MeshId),texture_id=tostring(instance.TextureId),
                    detail="source coverage not established; appearance/unsupported-policy qualification unchanged"}
            end
            if class == "ParticleEmitter" then
                local disabled = instance.Enabled == false or tonumber(instance.Rate) == 0
                add(instance.Texture, "particle_texture", disabled and "ignored" or "unknown",
                    disabled and "authored emitter disabled or zero continuous rate (burst behavior unverified)"
                    or "active authored emitter has no inspected renderer submission route", instance, not disabled)
            elseif (class == "ImageLabel" or class == "ImageButton") and not gui_referents[tostring(instance.Referent)] then
                uninspected_gui[class] = true
                add(instance.Image, "gui_image", "unknown", "authored image not reconciled with an effective SurfaceGui descriptor", instance)
            end
        end
        -- Only these bounded routes are established here. Presence of an
        -- uninspected active category remains UNKNOWN, regardless of frustum.
        for _, class in ipairs({ "MeshPart", "UnionOperation", "SpecialMesh", "SurfaceAppearance", "MaterialVariant", "ImageLabel", "ImageButton", "ViewportFrame", "VideoFrame", "Beam", "Trail", "ParticleEmitter" }) do
            categories[class] = (classes[class] or 0) == 0 and "NOT APPLICABLE (whole DataModel census)" or "UNKNOWN"
            if (classes[class] or 0) > 0 then
                if (class == "ImageLabel" or class == "ImageButton") and not uninspected_gui[class] then
                    categories[class] = "all authored images reconciled with effective SurfaceGui source descriptors"
                else coverage_gaps[#coverage_gaps + 1] = class .. " source route requires inspection" end
            end
        end
    else coverage_gaps[#coverage_gaps + 1] = "whole DataModel census unavailable" end
    local result = M.classify(resources, #coverage_gaps == 0)
    result.applicability = { runtime_parts = #(core.parts or {}), inspected_parts = part_total,
        retained_face_layers = retained_layers, retained_geometry_routes = geometry_routes, classes = classes, categories = categories,
        scope = "whole committed scene, fixed recorded lighting and properties; no frustum exclusion; not day/night compatibility" }
    result.boundary = "Run-boundary retained resolver/sampler caches, all effective parts and generated face-layer sources, used material descriptors, whole DataModel category census. No resolver calls."
    result.coverage_gaps = coverage_gaps
    result.coverage_details = coverage_details
    local sun = core._celestial_texture_entries and core._celestial_texture_entries.sun
    local sun_image = sun and (sun.handle and sun.handle.texture or sun.texture)
    local sun_key = sun and asset_key(sun.asset_path, "texture")
    local sun_path = sun_key and core._asset_path_cache and core._asset_path_cache[sun_key]
    local sun_bytes = type(sun_path) == "string" and love.filesystem.read(sun_path)
    result.sun_binding = { reference = sun and sun.asset_path or "UNKNOWN", canonical_key = known(sun_key),
        resolved_path = known(sun_path), sha256 = sun_bytes and hash(sun_bytes) or "UNKNOWN",
        real_directory = type(sun_path) == "string" and known(love.filesystem.getRealDirectory(sun_path)) or "UNKNOWN",
        uses_loaded_texture = sun_image ~= nil and sun_image ~= core._white_texture and sun_image ~= core._sky_default_sun_texture }
    result.sky = sky
    return result
end

function M.capture(game, frames, completion, manifest_path)
    local core = game and game._core
    assert(core, "run record needs live renderer")
    local stats = core:get_stats()
    local status = game:get_map_load_status()
    local renderer, api, vendor, device = love.graphics.getRendererInfo()
    local window_width, window_height, window_flags = love.window.getMode()
    local pixel_width, pixel_height = love.graphics.getPixelDimensions()
    local source = "UNKNOWN"
    local source_path = manifest_path or os.getenv("RBX_PROFILE_SOURCE")
    if source_path then
        local bytes=read_file(source_path)
        local ok,value=pcall(json.decode,bytes or "")
        source=ok and value or {manifest_error="unreadable/invalid manifest: "..source_path}
    end
    local bytes = core.map_path and love.filesystem.read(core.map_path)
    local counts = {}
    for _, key in ipairs({ "part_count", "opaque_part_count", "transparent_part_count", "visible_opaque_part_count",
        "visible_transparent_part_count", "draw_call_count", "triangles", "missing_mesh_count", "mesh_part_count",
        "missing_union_mesh_count", "visible_unions", "visible_mesh_parts", "surface_gui_count" }) do counts[key] = known(stats[key]) end
    counts.loaded_parts = known(core._loaded_part_count)
    local settings = {}
    for _, key in ipairs({ "render_backend_name", "msaa_samples", "texture_filter_profile", "directional_shadows",
        "directional_shadow_map_size", "directional_shadow_distance", "enable_frame_post_process",
        "_active_near_clip", "_active_far_clip", "_render_depth_format" }) do settings[key] = known(core[key]) end
    settings.resolution = { width = known(core._last_render_target_width), height = known(core._last_render_target_height) }
    settings.window = { width = window_width, height = window_height,
        pixel_width = pixel_width, pixel_height = pixel_height,
        dpi_scale = love.window.getDPIScale(), msaa = known(window_flags.msaa),
        vsync = known(window_flags.vsync), highdpi = known(window_flags.highdpi),
        usedpiscale = known(window_flags.usedpiscale), fullscreen = known(window_flags.fullscreen),
        display = known(window_flags.display) }
    settings.vsync = known(window_flags.vsync)
    settings.frame_limiter_seconds = known(G and G.min_dt)
    settings.display = {}
    for _, key in ipairs({ "rate", "vsync", "renderscale", "resolution", "shadows" }) do
        local option = CFG and CFG.getSetting and CFG:getSetting(key)
        settings.display[key] = known(option and option.value)
    end
    -- Inspect only retained targets at this boundary. No readback, rendering,
    -- resource creation, resolver calls or observer installation occurs here.
    local function target(canvas)
        if not canvas then return { present = false } end
        local ok, value = pcall(function()
            return { present = true, width = canvas:getWidth(), height = canvas:getHeight(),
                format = canvas:getFormat(), msaa = canvas:getMSAA() }
        end)
        return ok and value or { present = true, inspection_error = tostring(value) }
    end
    local post = core._post_process
    settings.targets = { scene = target(post and post.scene_canvas),
        scene_depth = target(post and post.scene_depth), output = target(core._render_canvas),
        output_depth = target(core._render_depth_canvas), atlas = target(core._directional_shadow_atlas),
        atlas_depth = target(core._directional_shadow_depth) }
    settings.experimental_shadow_enumeration = core._experimental_shadow_enumeration == true
    settings.hdr = { requested_experimental_mode = known(os.getenv("LOVE_EXPERIMENTAL_RBX_RENDERING")),
        required_format = known(post and post._required_scene_format),
        forced_format = known(post and post._force_scene_format),
        actual_format = known(post and post.scene_format),
        actual_hdr = known(post and post.scene_is_hdr),
        actual_samples = known(post and post.scene_samples) }
    local world = core._physics_world
    local physics = { enabled = known(core.physics_enabled), world_present = world ~= nil,
        authored_parts = #(core.parts or {}), anchored_parts = 0, unanchored_parts = 0,
        unclassified_parts = 0 }
    for _, part in ipairs(core.parts or {}) do
        if part.Anchored == true then physics.anchored_parts = physics.anchored_parts + 1
        elseif part.Anchored == false then physics.unanchored_parts = physics.unanchored_parts + 1
        else physics.unclassified_parts = physics.unclassified_parts + 1 end
    end
    if world then
        physics.bodies, physics.static_bodies, physics.dynamic_bodies, physics.sleeping_bodies =
            #(world.bodies or {}), 0, 0, 0
        for _, body in ipairs(world.bodies or {}) do
            if body.is_static then physics.static_bodies = physics.static_bodies + 1
            else
                physics.dynamic_bodies = physics.dynamic_bodies + 1
                if body.sleeping then physics.sleeping_bodies = physics.sleeping_bodies + 1 end
            end
        end
        for _, key in ipairs({ "active_count", "contact_count", "last_substeps", "accumulator",
            "transform_updates_from_physics", "full_render_rebuilds_from_physics" }) do
            physics[key] = known(world[key])
        end
        physics.accounting = {}
        for key, value in pairs(world.time_accounting or {}) do
            if type(value) == "number" or type(value) == "boolean" or type(value) == "string" then
                physics.accounting[key] = value
            end
        end
    end
    local record = {
        schema_version = 1, run_id = os.getenv("RBX_PROFILE_RUN_ID") or "UNKNOWN", timestamp_utc = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        source = source, map_sha256 = bytes and hash(bytes) or "UNKNOWN", love_version = table.concat({ love.getVersion() }, ".", 1, 3),
        graphics = { renderer = known(renderer), api = known(api), vendor = known(vendor), device = known(device) },
        requested = { project = os.getenv("WAVE_PROJECT") or "rbx", map = os.getenv("RBX_MAP") or "assets/rbx/maps/Classic-Crossroads.rbxl",
            physics = os.getenv("RBX_PHYSICS") == "1", remote_assets = false, remote_meshes = false },
        effective = { project = known(G and G.project), map = known(core.map_path), physics = known(core.physics_enabled),
            remote_assets = known(core.allow_remote_asset_fetch), remote_meshes = known(core.allow_remote_mesh_fetch) },
        settings = settings, scene_counts = counts, rendered_frames = frames,
        physics = physics,
        lighting = core.get_lighting_state_snapshot and core:get_lighting_state_snapshot() or "UNKNOWN",
        post_process = post and post.diagnostics and post:diagnostics(core.lighting_state) or "UNKNOWN",
        memory = { lua_heap_kib = collectgarbage("count"), graphics = love.graphics.getStats(),
            scope = "boundary snapshots; Lua heap and graphics counters, not peak or process memory" },
        commit = { active = known(status.active), done = known(status.done), success = known(status.success), map = known(status.map_path),
            phase = known(status.phase), raw_error = known(status.error), load_generation = known(core._async_map_load_id),
            scene_revision = known(core._scene_revision), loaded_parts = known(core._loaded_part_count) },
        cache = { process = os.getenv("RBX_PROFILE_CACHE_CONTEXT") or "UNKNOWN", os_disk_cache = "UNKNOWN",
            parsed_map_cache_hit = known(core._load_stage_times and core._load_stage_times.map_cache_hit),
            mesh_hits = known(stats.mesh_cache_hits), mesh_misses = known(stats.mesh_cache_misses),
            texture_hits = known(stats.texture_cache_hits), texture_misses = known(stats.texture_cache_misses) },
        visual_assets = M.assets(core, stats), completion = { status = completion, process_exit_code = "UNKNOWN (launcher records exit)" },
    }
    return M.validate(record)
end

function M.save(path, record)
    assert(not love.filesystem.getInfo(path), "refusing to overwrite run record")
    assert(love.filesystem.write(path, json.encode(record)))
    print("[rbx-profile-record] " .. love.filesystem.getSaveDirectory() .. "/" .. path)
end
return M
