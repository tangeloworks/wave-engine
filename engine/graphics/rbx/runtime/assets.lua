-- load meshes, textures and materials for the renderer
-- mesh.lua handles mesh decoding, while this module unwraps containers and uploads the results

RBX._asset_paths = runtime_require("asset_paths.lua")
local runtime_coords = runtime_require("coords.lua")
local authored_srgb_to_gpu = runtime_coords.srgb_to_gpu
local LocalMeshCache = runtime_require("local_mesh_cache.lua")
local EmbeddedMeshCache = runtime_require("embedded_mesh_cache.lua")
local RemoteMesh = runtime_require("remote_mesh.lua")
local RemoteTexture = runtime_require("remote_texture.lua")
RBX._alpha_bleed = RBX._alpha_bleed or runtime_require("alpha_bleed.lua")
-- keep this on the shared namespace: assets.lua sits on LuaJIT's module-local
-- limit, and Atmosphere's shader block is consumed by both world and sky
RBX._atmosphere = RBX._atmosphere or runtime_require("atmosphere.lua")

function maybe_decompress_gzip_data(data)
    if type(data) ~= "string" or #data < 2 then
        return nil
    end
    if data:byte(1) ~= 0x1F or data:byte(2) ~= 0x8B then
        return nil
    end
    local ok, decompressed = pcall(love.data.decompress, "gzip", data)
    if ok and type(decompressed) == "string" and decompressed ~= "" then
        return decompressed
    end

    ok, decompressed = pcall(love.data.decompress, "string", "gzip", data)
    if ok and type(decompressed) == "string" and decompressed ~= "" then
        return decompressed
    end

    return nil
end

function RBX._get_renderable_mesh_score(mesh)
    if type(mesh) ~= "table" then
        return -1
    end
    if mesh.source_kind == "csg_mesh" then
        return 4
    end
    if mesh.source_kind == "csg_child_parts" then
        return 3
    end
    if mesh.source_kind == "mesh" then
        return 2
    end
    if mesh.source_kind == "csg_physics" then
        return 1
    end
    return 0
end

function RBX._choose_preferred_renderable_mesh(...)
    local best_mesh = nil
    local best_score = -1

    for i = 1, select("#", ...) do
        local mesh = select(i, ...)
        local score = RBX._get_renderable_mesh_score(mesh)
        if score > best_score then
            best_mesh = mesh
            best_score = score
        end
    end

    return best_mesh
end

function looks_like_roblox_xml(data)
    if type(data) ~= "string" or data == "" then
        return false
    end
    return safe_lower(data:sub(1, 256)):find("<roblox", 1, true) ~= nil
end

function walk_instance_tree(roots, visit)
    if type(roots) ~= "table" or type(visit) ~= "function" then
        return nil
    end

    local function walk(instance)
        if type(instance) ~= "table" then
            return nil
        end

        local result = visit(instance)
        if result ~= nil then
            return result
        end

        local children = instance.Children
        if type(children) == "table" then
            for i = 1, #children do
                result = walk(children[i])
                if result ~= nil then
                    return result
                end
            end
        end

        return nil
    end

    for i = 1, #roots do
        local result = walk(roots[i])
        if result ~= nil then
            return result
        end
    end

    return nil
end

parse_renderable_mesh_data_internal = nil

function try_nested_renderable_mesh_data(candidate, depth)
    if type(candidate) ~= "string" or candidate == "" then
        return nil
    end
    return parse_renderable_mesh_data_internal(candidate, (depth or 0) + 1)
end

function extract_renderable_mesh_data_from_tree(roots, depth)
    local best_mesh = nil
    local best_score = -1

    walk_instance_tree(roots, function(instance)
        for i = 1, #CSG_EMBEDDED_MESH_FIELDS do
            local field_name = CSG_EMBEDDED_MESH_FIELDS[i]
            local from_field = try_nested_renderable_mesh_data(instance[field_name], depth)
            local score = RBX._get_renderable_mesh_score(from_field)
            if score > best_score then
                best_mesh = from_field
                best_score = score
                -- a render CSG is the maximum-precedence source. Later fields
                -- cannot replace it (equal scores preserve authored order), so
                -- decoding their nested containers is provably dead work
                if best_score >= 4 then
                    return best_mesh
                end
            end
        end
    end)

    return best_mesh
end

function try_xml_renderable_mesh_property(properties_block, shared_strings, property_name, depth)
    if type(properties_block) ~= "string" or type(property_name) ~= "string" then
        return nil
    end

    local shared_ref = read_xml_shared_string_ref(properties_block, property_name)
    if shared_ref and type(shared_strings) == "table" then
        local parsed = try_nested_renderable_mesh_data(shared_strings[shared_ref], depth)
        if parsed then
            return parsed
        end
    end

    return try_nested_renderable_mesh_data(read_named_content_or_string(properties_block, property_name), depth)
end

function extract_renderable_mesh_data_from_xml(xml, depth)
    local shared_strings = parse_xml_shared_strings(xml)
    local cursor = 1
    local best_mesh = nil
    local best_score = -1

    while true do
        local item_start, item_tag_end = xml:find("<Item%s+class=\"([^\"]+)\"[^>]*>", cursor)
        if not item_start then
            break
        end

        local close_start, close_end = find_matching_item_close(xml, item_tag_end + 1)
        if not close_start then
            break
        end

        local item_body = xml:sub(item_tag_end + 1, close_start - 1)
        local properties_block = item_body:match("<Properties>(.-)</Properties>")
        if properties_block then
            for i = 1, #CSG_EMBEDDED_MESH_FIELDS do
                local property_name = CSG_EMBEDDED_MESH_FIELDS[i]
                local parsed = try_xml_renderable_mesh_property(properties_block, shared_strings, property_name, depth)
                local score = RBX._get_renderable_mesh_score(parsed)
                if score > best_score then
                    best_mesh = parsed
                    best_score = score
                    if best_score >= 4 then
                        return best_mesh
                    end
                end
            end
        end

        cursor = close_end + 1
    end

    return best_mesh
end

function extract_renderable_mesh_data_from_asset(data, depth)
    if starts_with(data, RBX.BINARY_SIGNATURE) then
        local roots = decode_rbxl_binary(data)
        if roots then
            return extract_renderable_mesh_data_from_tree(roots, depth)
        end
        return nil
    end

    if looks_like_roblox_xml(data) then
        return extract_renderable_mesh_data_from_xml(data, depth)
    end

    return nil
end

-- require() is not free and this runs once per embedded payload on a 2000-union map
local mesh_module = nil
local function rbx_mesh()
    if mesh_module == nil then
        mesh_module = require("engine/graphics/rbx/mesh")
    end
    return mesh_module
end
RBX._mesh_module = rbx_mesh

---Structured tally of payloads that reached the end of the decode chain without
---producing geometry, i.e. parts that will silently render as a Block
---
---one line per DISTINCT failure code, not per part: a map with 1,018 identical
---failures should say so once. Benign codes (a CSGPHS v0 "BLOCK" token, a CSGK
---content-key reference) are counted but never printed -- for those the file
---genuinely holds no mesh and the part box is the right answer
local MESH_DECODE_PRINT_LIMIT = 8

function RBX._note_mesh_decode_failure(reason, info)
    local report = RBX._mesh_decode_report
    if not report then
        report = { total = 0, benign = 0, by_code = {}, order = {} }
        RBX._mesh_decode_report = report
    end
    local code = (type(info) == "table" and info.code) or "unknown"
    report.total = report.total + 1

    local entry = report.by_code[code]
    if not entry then
        entry = {
            code = code,
            count = 0,
            format = type(info) == "table" and info.format or nil,
            version = type(info) == "table" and info.version or nil,
            benign = rbx_mesh().BENIGN_FAILURE_CODES[code] == true,
            message = reason,
        }
        report.by_code[code] = entry
        report.order[#report.order + 1] = entry
    end
    entry.count = entry.count + 1
    if entry.benign then
        report.benign = report.benign + 1
        return
    end
    if entry.count == 1 and #report.order <= MESH_DECODE_PRINT_LIMIT then
        print("[rbx] no mesh geometry decoded [" .. code .. "] " .. tostring(reason)
            .. "  -- the part renders as a Block")
    end
end

function parse_renderable_mesh_data(data)
    local parsed, reason, info = parse_renderable_mesh_data_internal(data, 0)
    if not parsed and type(data) == "string" and data ~= "" then
        RBX._note_mesh_decode_failure(reason, info)
    end
    return parsed
end

---@return table|nil parsed, string|nil reason, table|nil info
---the reason/info pair is mesh.parse's structured diagnosis, propagated so
---parse_renderable_mesh_data can tally it once the WHOLE chain (gzip unwrap, direct
---decode, nested-container walk) has failed. Reporting it any earlier would flag
---every container payload, which fails mesh.parse by design and then succeeds via
---extract_renderable_mesh_data_from_asset
parse_renderable_mesh_data_internal = function(data, depth)
    if type(data) ~= "string" or data == "" then
        return nil
    end

    local decompressed = maybe_decompress_gzip_data(data)
    local inner_reason, inner_info
    if decompressed and decompressed ~= data then
        local parsed
        parsed, inner_reason, inner_info = parse_renderable_mesh_data_internal(decompressed, (depth or 0) + 1)
        if parsed then
            return parsed
        end
        -- keep the INNER diagnosis: describing the still-compressed bytes as "no
        -- version line, no CSG magic" is true and useless
    end

    -- ONE decoder, ONE call, with the real options
    --
    -- the old two-call shape passed accurate_face_axes ONLY on the fallback branch --
    -- which CSGPHS never reached, because mesh.parse had already handled it. So the
    -- flag was live in geometry.lua (FACE_AXES) and render.lua (needs_csg_z_mirror)
    -- but dead in mesh.lua (build_basis_metadata's flip_back_axis), and those three
    -- are explicitly COUPLED: mesh.lua:build_basis_metadata says dropping one without
    -- the others U-mirrors unions on their +/-Z faces. Routing every payload through
    -- one call with one option table is what makes the flag mean one thing
    local parsed, reason, info = rbx_mesh().parse(data, {
        crease_degrees = 65,
        accurate_face_axes = RBX._accurate_face_axes == true,
    })
    if parsed then
        return parsed
    end
    if inner_info then
        reason, info = inner_reason, inner_info
    end

    if (depth or 0) >= 4 then
        return nil, reason, info
    end

    local nested = extract_renderable_mesh_data_from_asset(data, depth or 0)
    if nested then
        return nested
    end
    if type(info) == "table" and info.code == "payload_is_container" then
        -- the container WAS walked and held nothing renderable. mesh.parse cannot know
        -- that -- it only saw a container -- so the final word belongs here
        return nil,
            string.format("nested Roblox container (%d bytes) holds no decodable mesh payload", #data),
            { code = "container_holds_no_mesh", format = "container" }
    end
    return nil, reason, info
end

function copy_rgb(color)
    if type(color) ~= "table" then
        return { 1, 1, 1 }
    end
    return {
        clamp(color[1] or color.r or 1, 0, 1),
        clamp(color[2] or color.g or 1, 0, 1),
        clamp(color[3] or color.b or 1, 0, 1),
    }
end

function contact_ao_for_normal(top, bottom, side, overall, nx, ny, nz)
    top = clamp(tonumber(top) or 0, 0, 1)
    bottom = clamp(tonumber(bottom) or 0, 0, 1)
    side = clamp(tonumber(side) or 0, 0, 1)
    overall = clamp(tonumber(overall) or 0, 0, 1)
    nx = tonumber(nx) or 0
    ny = tonumber(ny) or 0
    nz = tonumber(nz) or 0
    local ax = math.abs(nx)
    local ay = math.abs(ny)
    local az = math.abs(nz)
    if ay >= ax and ay >= az then
        if ny >= 0 then
            return clamp(math.max(top, overall * 0.30), 0, 1)
        end
        return clamp(math.max(bottom, overall * 0.50), 0, 1)
    end
    return clamp(math.max(side, overall * 0.35), 0, 1)
end
RBX._contact_ao_for_normal = contact_ao_for_normal

-- insert the same shadow receiver code into every frame-lit shader
-- keep the begin and end markers stable: a driver failure switches the whole set to its fallback
local DIRECTIONAL_SHADOW_CASCADE_NEXT_SAMPLE_GLSL = [[
        if (blend > 0.0) {
            float nextVisibility = sampleDirectionalShadowCascade(
                cascade + 1.0, worldPos, receiverNormal, ndotl);
            visibility = mix(visibility, nextVisibility, blend);
        }
]]

DIRECTIONAL_SHADOW_FRAME_GLSL = [[
// RBX_DIRECTIONAL_SHADOW_FRAME_BEGIN
extern Image uShadowAtlas;
uniform mat4 uShadowMatrix0;
uniform mat4 uShadowMatrix1;
uniform mat4 uShadowMatrix2;
uniform vec3 uShadowCameraForward;
uniform vec3 uShadowSunDirection;
uniform vec3 uShadowCascadeBias;
uniform vec3 uShadowCascadeTexelDepth;
uniform vec3 uShadowBiasRight;
uniform vec3 uShadowBiasUp;
uniform vec4 uShadowCascadeSplits;
// xy = inverse atlas dimensions, z = one-cascade horizontal UV scale,
// w = enabled.  The atlas is always one row of three equally-sized tiles.
uniform vec4 uShadowAtlasInfo;
// x = ShadowSoftness, y = slope-bias scale, z = cascade blend fraction,
// w = minimum directional visibility in a fully shadowed texel.
uniform vec4 uShadowParams;
// Internal diagnostic: 0 = normal shading, 1 = visualize cascade index.
uniform float uShadowCascadeDebug;

float decodeDirectionalShadowDepth(vec3 encoded)
{
    return clamp(dot(encoded, vec3(1.0, 1.0 / 255.0,
        1.0 / 65025.0)), 0.0, 1.0);
}

mat4 directionalShadowMatrix(float cascade)
{
    if (cascade < 0.5) {
        return uShadowMatrix0;
    }
    if (cascade < 1.5) {
        return uShadowMatrix1;
    }
    return uShadowMatrix2;
}

vec4 directionalShadowClip(float cascade, vec3 worldPos)
{
    return directionalShadowMatrix(cascade) * vec4(worldPos, 1.0);
}

float sampleDirectionalShadowPoint(
    vec2 requestedUv, vec2 receiverUv, float receiverDepth,
    vec2 receiverPlaneDepthPerTexel, float bias,
    float tileMin, float tileMax)
{
    // Never clamp an invalid tap onto the last texel of a cascade. Doing so
    // repeats an unrelated edge depth and can itself form a dark atlas-shaped
    // band. A half-texel guard keeps nearest filtering wholly inside the tile;
    // taps beyond it represent no shadow-map coverage and are unshadowed.
    vec2 atlasTexel = uShadowAtlasInfo.xy;
    vec2 safeMin = vec2(tileMin + atlasTexel.x * 0.5,
        atlasTexel.y * 0.5);
    vec2 safeMax = vec2(tileMax - atlasTexel.x * 0.5,
        1.0 - atlasTexel.y * 0.5);
    if (requestedUv.x < safeMin.x || requestedUv.x > safeMax.x
        || requestedUv.y < safeMin.y || requestedUv.y > safeMax.y) {
        return 1.0;
    }

    // Nearest filtering reads the center of the addressed hardware texel.
    // Move the receiver comparison depth to that same point on its tangent
    // plane. This removes slope-dependent self-shadowing without moving the
    // whole receiver toward the light (which would detach real contact
    // shadows, especially in the far cascade or under a low sun).
    vec2 sampledCenter = (floor(requestedUv / atlasTexel) + vec2(0.5))
        * atlasTexel;
    vec2 sampledOffsetTexels =
        (sampledCenter - receiverUv) / atlasTexel;
    float tapReceiverDepth = receiverDepth
        + dot(sampledOffsetTexels, receiverPlaneDepthPerTexel);
    float storedDepth = decodeDirectionalShadowDepth(
        Texel(uShadowAtlas, sampledCenter).rgb);
    return tapReceiverDepth - bias <= storedDepth ? 1.0 : 0.0;
}

float sampleDirectionalShadowTap(
    vec2 requestedUv, vec2 receiverUv, float receiverDepth,
    vec2 receiverPlaneDepthPerTexel, float bias,
    float tileMin, float tileMax)
{
    // Interpolate comparison results, never encoded depths. Nearest PCF leaves
    // whole-texel plateaus and discrete contrast jumps as an edge is projected.
    // Each neighbor keeps its own coverage guard and receiver-plane correction.
    vec2 texel = uShadowAtlasInfo.xy;
    // Preserve the kernel-location coverage contract as well: a requested tap
    // outside the tile's safe domain is wholly unshadowed. Interpolation must
    // not reach back into a tile from an invalid location.
    if (requestedUv.x < tileMin + texel.x * 0.5
        || requestedUv.x > tileMax - texel.x * 0.5
        || requestedUv.y < texel.y * 0.5
        || requestedUv.y > 1.0 - texel.y * 0.5) {
        return 1.0;
    }
    vec2 grid = requestedUv / texel - vec2(0.5);
    vec2 fraction = fract(grid);
    vec2 center = (floor(grid) + vec2(0.5)) * texel;
    float a = sampleDirectionalShadowPoint(center, receiverUv, receiverDepth,
        receiverPlaneDepthPerTexel, bias, tileMin, tileMax);
    float b = sampleDirectionalShadowPoint(center + vec2(texel.x, 0.0),
        receiverUv, receiverDepth, receiverPlaneDepthPerTexel, bias, tileMin, tileMax);
    float c = sampleDirectionalShadowPoint(center + vec2(0.0, texel.y),
        receiverUv, receiverDepth, receiverPlaneDepthPerTexel, bias, tileMin, tileMax);
    float d = sampleDirectionalShadowPoint(center + texel, receiverUv, receiverDepth,
        receiverPlaneDepthPerTexel, bias, tileMin, tileMax);
    return mix(mix(a, b, fraction.x), mix(c, d, fraction.x), fraction.y);
}

float sampleDirectionalShadowCascade(
    float cascade, vec3 worldPos, vec3 worldNormal, float ndotl)
{
    mat4 shadowMatrix = directionalShadowMatrix(cascade);
    vec4 clip = shadowMatrix * vec4(worldPos, 1.0);
    if (abs(clip.w) <= 0.000001) {
        return 1.0;
    }
    vec3 projected = clip.xyz / clip.w;
    vec2 localUv = projected.xy * 0.5 + 0.5;
    float receiverDepth = projected.z * 0.5 + 0.5;
    if (localUv.x <= 0.0 || localUv.x >= 1.0
        || localUv.y <= 0.0 || localUv.y >= 1.0
        || receiverDepth <= 0.0 || receiverDepth >= 1.0) {
        return 1.0;
    }

    float tileScale = uShadowAtlasInfo.z;
    float tileMin = cascade * tileScale;
    float tileMax = tileMin + tileScale;
    vec2 atlasUv = vec2(tileMin + localUv.x * tileScale, localUv.y);
    float softness = clamp(uShadowParams.x, 0.0, 1.0);
    float kernelRadius = mix(0.65, 2.15, softness);
    // The atlas is 3*T pixels wide and each cascade tile is T pixels wide.
    // One hardware texel is therefore 1/(3*T) in atlas UV on X; the tile
    // scale is already accounted for when localUv is mapped into atlasUv.
    vec2 texel = vec2(
        uShadowAtlasInfo.x,
        uShadowAtlasInfo.y) * kernelRadius;
    // Normal/slope bias remains in normalized light-depth units. Per-cascade
    // base terms account for increasing world-space texel size.
    float baseBias = cascade < 0.5 ? uShadowCascadeBias.x
        : (cascade < 1.5 ? uShadowCascadeBias.y
            : uShadowCascadeBias.z);
    float cascadeTexelDepth = cascade < 0.5
        ? uShadowCascadeTexelDepth.x
        : (cascade < 1.5 ? uShadowCascadeTexelDepth.y
            : uShadowCascadeTexelDepth.z);
    vec2 receiverPlaneDepthPerTexel = cascadeTexelDepth * vec2(
        dot(worldNormal, uShadowBiasRight),
        dot(worldNormal, uShadowBiasUp)) / max(ndotl, 0.05);
    float bias = baseBias
        + max(0.0, 1.0 - ndotl) * uShadowParams.y;

    float visibility = 0.0;
    // Nine fixed kernel locations, each with four bounded comparisons (36
    // maximum). ShadowSoftness changes footprint, not an unbounded loop count.
    visibility += sampleDirectionalShadowTap(
        atlasUv + texel * vec2(-1.0, -1.0), atlasUv, receiverDepth,
        receiverPlaneDepthPerTexel, bias, tileMin, tileMax);
    visibility += sampleDirectionalShadowTap(
        atlasUv + texel * vec2(0.0, -1.0), atlasUv, receiverDepth,
        receiverPlaneDepthPerTexel, bias, tileMin, tileMax);
    visibility += sampleDirectionalShadowTap(
        atlasUv + texel * vec2(1.0, -1.0), atlasUv, receiverDepth,
        receiverPlaneDepthPerTexel, bias, tileMin, tileMax);
    visibility += sampleDirectionalShadowTap(
        atlasUv + texel * vec2(-1.0, 0.0), atlasUv, receiverDepth,
        receiverPlaneDepthPerTexel, bias, tileMin, tileMax);
    visibility += sampleDirectionalShadowTap(
        atlasUv, atlasUv, receiverDepth,
        receiverPlaneDepthPerTexel, bias, tileMin, tileMax);
    visibility += sampleDirectionalShadowTap(
        atlasUv + texel * vec2(1.0, 0.0), atlasUv, receiverDepth,
        receiverPlaneDepthPerTexel, bias, tileMin, tileMax);
    visibility += sampleDirectionalShadowTap(
        atlasUv + texel * vec2(-1.0, 1.0), atlasUv, receiverDepth,
        receiverPlaneDepthPerTexel, bias, tileMin, tileMax);
    visibility += sampleDirectionalShadowTap(
        atlasUv + texel * vec2(0.0, 1.0), atlasUv, receiverDepth,
        receiverPlaneDepthPerTexel, bias, tileMin, tileMax);
    visibility += sampleDirectionalShadowTap(
        atlasUv + texel * vec2(1.0, 1.0), atlasUv, receiverDepth,
        receiverPlaneDepthPerTexel, bias, tileMin, tileMax);
    visibility /= 9.0;
    return mix(clamp(uShadowParams.w, 0.0, 1.0), 1.0, visibility);
}

float computeDirectionalShadow(vec3 worldPos, vec3 worldNormal)
{
    if (uShadowAtlasInfo.w < 0.5) {
        return 1.0;
    }
    vec3 receiverNormal = normalize(worldNormal);
    float ndotl = max(dot(receiverNormal,
        normalize(uShadowSunDirection)), 0.0);
    if (ndotl <= 0.0001) {
        return 1.0;
    }
    float cameraDepth = max(dot(
        worldPos - uCameraPos, uShadowCameraForward), 0.0);
    float cascade = cameraDepth <= uShadowCascadeSplits.x ? 0.0
        : (cameraDepth <= uShadowCascadeSplits.y ? 1.0 : 2.0);
    if (uShadowCascadeDebug > 0.5) {
        return cascade < 0.5 ? 0.30 : (cascade < 1.5 ? 0.62 : 0.92);
    }
    float visibility = sampleDirectionalShadowCascade(
        cascade, worldPos, receiverNormal, ndotl);

    float splitStart = cascade < 0.5 ? 0.0
        : (cascade < 1.5 ? uShadowCascadeSplits.x
            : uShadowCascadeSplits.y);
    float splitEnd = cascade < 0.5 ? uShadowCascadeSplits.x
        : (cascade < 1.5 ? uShadowCascadeSplits.y
            : uShadowCascadeSplits.z);
    float blendWidth = max(
        (splitEnd - splitStart) * clamp(uShadowParams.z, 0.01, 0.30),
        0.001);
    float blend = smoothstep(splitEnd - blendWidth,
        splitEnd, cameraDepth);
    if (cascade < 1.5) {
]] .. DIRECTIONAL_SHADOW_CASCADE_NEXT_SAMPLE_GLSL .. [[
    } else {
        // Fade the last cascade to the unshadowed far field instead of ending
        // in a visible hard line at the configured shadow distance.
        visibility = mix(visibility, 1.0, blend);
    }
    return visibility;
}

vec4 directionalShadowCascadeDebugColor(vec3 worldPos)
{
    if (uShadowCascadeDebug < 0.5) {
        return vec4(0.0);
    }
    float cameraDepth = max(dot(
        worldPos - uCameraPos, uShadowCameraForward), 0.0);
    float cascade = cameraDepth <= uShadowCascadeSplits.x ? 0.0
        : (cameraDepth <= uShadowCascadeSplits.y ? 1.0 : 2.0);
    float splitStart = cascade < 0.5 ? 0.0
        : (cascade < 1.5 ? uShadowCascadeSplits.x
            : uShadowCascadeSplits.y);
    float splitEnd = cascade < 0.5 ? uShadowCascadeSplits.x
        : (cascade < 1.5 ? uShadowCascadeSplits.y
            : uShadowCascadeSplits.z);
    float blendWidth = max(
        (splitEnd - splitStart) * clamp(uShadowParams.z, 0.01, 0.30),
        0.001);
    float blend = smoothstep(splitEnd - blendWidth,
        splitEnd, cameraDepth);
    vec3 color0 = vec3(0.92, 0.12, 0.10);
    vec3 color1 = vec3(0.10, 0.88, 0.20);
    vec3 color2 = vec3(0.12, 0.30, 0.96);
    vec3 color = cascade < 0.5 ? color0
        : (cascade < 1.5 ? color1 : color2);
    vec3 nextColor = cascade < 0.5 ? color1
        : (cascade < 1.5 ? color2 : vec3(1.0));
    return vec4(mix(color, nextColor, blend), 1.0);
}
// RBX_DIRECTIONAL_SHADOW_FRAME_END
]]

DIRECTIONAL_SHADOW_DISABLED_GLSL = [[
// RBX_DIRECTIONAL_SHADOW_FRAME_BEGIN
float computeDirectionalShadow(vec3 worldPos, vec3 worldNormal)
{
    return 1.0;
}

vec4 directionalShadowCascadeDebugColor(vec3 worldPos)
{
    return vec4(0.0);
}
// RBX_DIRECTIONAL_SHADOW_FRAME_END
]]

function RBX._without_directional_shadow_glsl(source)
    if type(source) ~= "string" then
        return source
    end
    local begin_at = source:find(
        "// RBX_DIRECTIONAL_SHADOW_FRAME_BEGIN", 1, true)
    local _, end_at = source:find(
        "// RBX_DIRECTIONAL_SHADOW_FRAME_END", 1, true)
    if not begin_at or not end_at or end_at < begin_at then
        return source
    end
    return source:sub(1, begin_at - 1)
        .. DIRECTIONAL_SHADOW_DISABLED_GLSL
        .. source:sub(end_at + 1)
end

-- keep Atmosphere replaceable as one coherent shader block. some GLES
-- implementations accept the base lighting program but reject the additional
-- scattering functions/uniforms. Renderer initialization gets one final,
-- feature-disabled program variant instead of turning that capability gap
-- into a startup failure
ATMOSPHERE_FRAME_GLSL = [[
// RBX_ATMOSPHERE_FRAME_BEGIN
// RBX_ATMOSPHERE_FRAME_ACTIVE
]] .. RBX._atmosphere.FRAME_GLSL .. [[

vec3 rbxAtmosphereConfiguredColor()
{
    return uAtmosphere[0].rgb;
}

// The cubemap already contains the additive scattered sky radiance. Drawing
// a sun, moon, or star on top must therefore add only the body's transmitted
// radiance, not a second copy of the haze/glare background.
vec3 rbxAttenuateAtmosphereCelestial(vec3 rgb, vec3 viewDirection,
    vec3 sunDirection)
{
    if (uAtmosphere[2].w < 0.5) {
        return max(rgb, vec3(0.0));
    }
    vec3 safeView = rbxAtmosphereSafeDirection(
        viewDirection, vec3(0.0, 0.0, 1.0));
    vec3 safeSun = rbxAtmosphereSafeDirection(
        sunDirection, vec3(0.0, 1.0, 0.0));
    vec4 scatter = rbxAtmosphereScatter(safeView, safeSun);
    float horizon = clamp(1.0 - abs(safeView.y), 0.0, 1.0);
    float coverage = clamp(uAtmosphere[2].x * 0.075
            * ((0.35 + horizon * 0.65)
                - uAtmosphere[1].w * 0.18),
        0.0, 1.0);
    vec3 extinctionTint = mix(vec3(1.0),
        clamp(scatter.rgb, vec3(0.0), vec3(2.0)),
        coverage * 0.65);
    return max(rgb, vec3(0.0))
        * max(1.0 - coverage, 0.0) * extinctionTint;
}
// RBX_ATMOSPHERE_FRAME_END
]]

ATMOSPHERE_DISABLED_FRAME_GLSL = [[
// RBX_ATMOSPHERE_FRAME_BEGIN
// RBX_ATMOSPHERE_FRAME_DISABLED
vec3 rbxAtmosphereConfiguredColor()
{
    return vec3(1.0);
}
vec3 rbxApplyAtmosphere(vec3 rgb, vec3 worldPosition,
    vec3 cameraPosition, vec3 sunDirection)
{
    return max(rgb, vec3(0.0));
}
vec3 rbxApplyAtmosphereSky(vec3 rgb, vec3 viewDirection,
    vec3 sunDirection)
{
    return max(rgb, vec3(0.0));
}
vec3 rbxAttenuateAtmosphereCelestial(vec3 rgb, vec3 viewDirection,
    vec3 sunDirection)
{
    return max(rgb, vec3(0.0));
}
// RBX_ATMOSPHERE_FRAME_END
]]

function RBX._without_atmosphere_glsl(source)
    if type(source) ~= "string" then
        return source
    end
    local begin_at = source:find(
        "// RBX_ATMOSPHERE_FRAME_BEGIN", 1, true)
    local _, end_at = source:find(
        "// RBX_ATMOSPHERE_FRAME_END", 1, true)
    if not begin_at or not end_at or end_at < begin_at then
        return source
    end
    return source:sub(1, begin_at - 1)
        .. ATMOSPHERE_DISABLED_FRAME_GLSL
        .. source:sub(end_at + 1)
end

LIGHTING_FRAME_GLSL = DIRECTIONAL_SHADOW_FRAME_GLSL
    .. ATMOSPHERE_FRAME_GLSL .. [[
uniform vec4 uLighting0;
uniform vec4 uLighting1;
uniform vec4 uLighting2;
uniform vec4 uLighting3;
uniform vec4 uLighting4;
uniform vec4 uLighting5;
uniform vec4 uLighting6;
uniform vec4 uLighting7;
uniform vec4 uLighting8;
uniform vec4 uLighting9;
uniform vec4 uLighting10;
uniform vec4 uLighting11;
uniform vec4 uLighting12;
// Element zero stores ambient.rgb and the selected-light count in .w. The
// remaining four lights use six vec4 records each. One array means ONE
// shader:send per pack switch, and constant indices remain GLES2-safe.
// Layout: metadata=[0], slot i occupies [1+i*6 .. 1+i*6+5] = A,B,C,D,E,F.
uniform vec4 uLocalLights[25];
uniform float uLightingDebugView;
uniform float uLightingDebugLightType;

#define uSunDirection normalize(uLighting0.xyz)
#define uDirectionalIntensity uLighting0.w
#define uSunColorBase (vec3(1.0) + uLighting3.rgb * 0.45)
#define uSkyColor uLighting5.rgb
#define uGroundColor uLighting8.rgb
#define uAmbient uLighting8.w
#define uDiffuseStrength uLighting3.w
#define uSpecularStrength uLighting7.w
#define uRimStrength uLighting9.y
#define uNightFactor uLighting9.z
#define uFramePostActive uLighting9.w
#define uPostBrightness uLighting10.x
#define uPostContrast uLighting10.y
#define uPostSaturation uLighting10.z
#define uBloomIntensity uLighting10.w
#define uColorCorrectionTint uLighting11.rgb
#define uBloomThreshold uLighting11.w
#define uAtmosphereColor rbxAtmosphereConfiguredColor()
#define uAtmosphereStrength uLighting12.w
#define uAtmosphereSunDirection normalize(uLighting12.rgb)
// The active directional source is sun by day and moon by night. Keep the
// midnight source warm enough to produce Roblox-like light-facing highlights;
// darkness comes from ambient/environment attenuation and NdotL, not from
// making the moon color nearly black.
#define uSunColor mix(uSunColorBase, uSunColorBase * vec3(1.05, 0.88, 0.68), uNightFactor)
#define uReflectionSunWeight (0.35 * (1.0 - uNightFactor * 0.35))
#define uEnvironmentSpecularScale clamp(uLighting4.w, 0.0, 1.0)
#define uLocalLightResponseScale 1.0

float computeFrameSkyVisibility(vec3 n)
{
    float skyFacing = clamp(n.y * 0.45 + 0.55, 0.08, 1.0);
    float lightFacing = clamp(dot(n, uSunDirection), 0.0, 1.0);
    float globalShadows = clamp(uLighting1.w, 0.0, 1.0);
    float shadowSoftness = clamp(uLighting9.x, 0.0, 1.0);
    // GlobalShadows=false means NO shadowing anywhere: every surface sees the
    // full sky term (flat, bright, roblox legacy look). the old return 0.0
    // zeroed the environment term and made disabling shadows DARKER.
    if (globalShadows < 0.5) {
        return 1.0;
    }
    float skyVisibility = clamp(lightFacing * 0.35 + skyFacing * 0.65, 0.0, 1.0);
    float softFloor = clamp(0.18 + skyFacing * 0.35, 0.0, 1.0);
    return mix(skyVisibility, max(skyVisibility, softFloor), shadowSoftness * 0.55);
}

float computeContactFill(float contactAO)
{
    // This is baked scene/contact occlusion, not a material AO texture.
    if (uLighting1.w < 0.5) return 1.0;
    return mix(1.0, 0.62, clamp(contactAO, 0.0, 1.0));
}

float selectContactAO(vec3 localNormal, vec4 contact)
{
    vec3 n = normalize(localNormal);
    vec3 a = abs(n);
    float overall = clamp(contact.w, 0.0, 1.0);
    if (a.y >= a.x && a.y >= a.z) {
        if (n.y >= 0.0) {
            return clamp(max(contact.x, overall * 0.30), 0.0, 1.0);
        }
        return clamp(max(contact.y, overall * 0.50), 0.0, 1.0);
    }
    return clamp(max(contact.z, overall * 0.35), 0.0, 1.0);
}

vec3 computeFrameCoolAmbientTerm(vec3 n)
{
    // Ambient is an authored light color, not a generic brightness preset.
    // OutdoorAmbient contributes only its excess over Ambient, below.
    float backFacing = clamp(-dot(n, uSunDirection), 0.0, 1.0);
    return uLighting1.rgb + uLighting4.rgb
        * (backFacing * max(uDirectionalIntensity, 0.0) * 0.22);
}

vec3 computeFrameEnvironmentTerm(vec3 n)
{
    float skyFacing = clamp(n.y * 0.5 + 0.5, 0.0, 1.0);
    float skyVisibility = computeFrameSkyVisibility(n);
    float environmentDiffuse = clamp(uLighting2.w, 0.0, 1.0);
    vec3 ambientExcess = uLighting1.w < 0.5 ? vec3(0.0)
        : max(uLighting2.rgb - uLighting1.rgb, vec3(0.0));
    // Separate sky-derived illumination remains controlled by its own scale.
    // It does not turn OutdoorAmbient back on in the flat-lighting mode.
    vec3 hemiColor = mix(uGroundColor, uSkyColor, skyFacing);
    return ambientExcess * skyVisibility
        + hemiColor * (environmentDiffuse * (0.10 + skyVisibility * 0.26));
}

vec3 computeFrameAmbientTerm(vec3 n)
{
    return computeFrameCoolAmbientTerm(n) + computeFrameEnvironmentTerm(n);
}

vec3 computeFrameDiffuseTerm(vec3 n)
{
    float ndotl = max(dot(n, uSunDirection), 0.0);
    float intensity = max(uLighting0.w, 0.0);
    return uSunColor * (ndotl * uDiffuseStrength * intensity);
}

// PointLight / SpotLight / SurfaceLight evaluation, matching the spec
// baseline:
//   toLight     = lightPosition - worldPosition
//   dist        = length(toLight)
//   if dist >= Range -> 0
//   rangeAtten  = saturate(1 - (dist / Range)^2)
//   normalTerm  = max(dot(normal, L), 0)
//   contribution = Color * Brightness * rangeAtten * coneAtten * normalTerm
//
// SurfaceLight projects worldPos onto the face rectangle before computing
// distance, so the receiver gets the correct closest-point distance from
// the emitting face (not the part center). The cone test still uses the
// face normal so light does not leak backward through the parent face.
vec3 evaluatePackedLocalLight(vec4 a, vec4 b, vec4 c, vec4 d, vec4 e, vec4 f, vec3 n, vec3 worldPos)
{
    float lightType = floor(a.w + 0.5);
    if (uLightingDebugLightType > 0.5 && abs(lightType - uLightingDebugLightType) > 0.5) {
        return vec3(0.0);
    }
    vec3 source = a.xyz;
    vec3 direction = normalize(b.xyz);
    float range = max(b.w, 0.0);
    if (range <= 0.0001 || c.w <= 0.0001 || lightType <= 0.5) {
        return vec3(0.0);
    }

    // For SurfaceLight, clamp the receiver onto the emitting rectangle so
    // distance is measured from the closest point on the face, not the
    // part center. axisU/axisV are unit vectors along the face plane,
    // d.w and e.w are the half-extents of the face rectangle.
    if (lightType > 2.5) {
        vec3 axisU = d.xyz;
        vec3 axisV = e.xyz;
        vec3 rel = worldPos - source;
        source += axisU * clamp(dot(rel, axisU), -d.w, d.w);
        source += axisV * clamp(dot(worldPos - source, axisV), -e.w, e.w);
    }

    vec3 toLight = source - worldPos;
    float dist = length(toLight);
    if (dist >= range || dist <= 0.000001) {
        return vec3(0.0);
    }

    // Spec falloff: saturate(1 - (dist / Range)^2). Keeps light strong
    // through most of Range and drops off near the edge, matching the
    // Roblox PointLight reference. Range changes scale the entire curve
    // — doubling Range visibly doubles the lit radius. (the old extra
    // rangeAtten*rangeAtten square made lights die off far steeper than
    // the spec curve; removed for authenticity)
    float t = dist / range;
    float rangeAtten = clamp(1.0 - t * t, 0.0, 1.0);
    float coneAtten = 1.0;
    if (lightType > 1.5) {
        vec3 fromLight = normalize(worldPos - source);
        float coneDot = dot(direction, fromLight);
        // f.x = cos(half_angle), f.y = 1 / max(1 - cos(half_angle), eps).
        coneAtten = clamp((coneDot - f.x) * f.y, 0.0, 1.0);
    }

    vec3 L = normalize(toLight);
    float normalTerm = max(dot(n, L), 0.0);
    // contribution = Color * Brightness * rangeAtten * coneAtten * NdotL
    return c.rgb * (c.w * uLocalLightResponseScale * rangeAtten * coneAtten * normalTerm);
}

vec2 evaluatePackedLocalLightMetrics(vec4 a, vec4 b, vec4 c, vec4 d, vec4 e, vec4 f, vec3 n, vec3 worldPos)
{
    float lightType = floor(a.w + 0.5);
    if (uLightingDebugLightType > 0.5 && abs(lightType - uLightingDebugLightType) > 0.5) {
        return vec2(0.0);
    }
    vec3 source = a.xyz;
    vec3 direction = normalize(b.xyz);
    float range = max(b.w, 0.0);
    if (range <= 0.0001 || c.w <= 0.0001 || lightType <= 0.5) {
        return vec2(0.0);
    }
    if (lightType > 2.5) {
        vec3 axisU = d.xyz;
        vec3 axisV = e.xyz;
        vec3 rel = worldPos - source;
        source += axisU * clamp(dot(rel, axisU), -d.w, d.w);
        source += axisV * clamp(dot(worldPos - source, axisV), -e.w, e.w);
    }

    vec3 toLight = source - worldPos;
    float dist = length(toLight);
    if (dist >= range || dist <= 0.000001) {
        return vec2(0.0);
    }
    float t = dist / range;
    // same spec curve as the color path (no extra square)
    float rangeAtten = clamp(1.0 - t * t, 0.0, 1.0);
    float coneAtten = 1.0;
    if (lightType > 1.5) {
        vec3 fromLight = normalize(worldPos - source);
        float coneDot = dot(direction, fromLight);
        coneAtten = clamp((coneDot - f.x) * f.y, 0.0, 1.0);
    }
    vec3 L = normalize(toLight);
    float normalTerm = max(dot(n, L), 0.0);
    return vec2(rangeAtten * coneAtten, normalTerm);
}

vec3 computeLocalLightContribution(vec3 n, vec3 worldPos)
{
    float localLightCount = uLocalLights[0].w;
    vec3 localLight = uLocalLights[0].rgb;
    if (localLightCount > 0.5) {
        localLight += evaluatePackedLocalLight(uLocalLights[1], uLocalLights[2], uLocalLights[3],
            uLocalLights[4], uLocalLights[5], uLocalLights[6], n, worldPos);
    }
    if (localLightCount > 1.5) {
        localLight += evaluatePackedLocalLight(uLocalLights[7], uLocalLights[8], uLocalLights[9],
            uLocalLights[10], uLocalLights[11], uLocalLights[12], n, worldPos);
    }
    if (localLightCount > 2.5) {
        localLight += evaluatePackedLocalLight(uLocalLights[13], uLocalLights[14], uLocalLights[15],
            uLocalLights[16], uLocalLights[17], uLocalLights[18], n, worldPos);
    }
    if (localLightCount > 3.5) {
        localLight += evaluatePackedLocalLight(uLocalLights[19], uLocalLights[20], uLocalLights[21],
            uLocalLights[22], uLocalLights[23], uLocalLights[24], n, worldPos);
    }
    return localLight;
}

vec2 computeLocalLightMetrics(vec3 n, vec3 worldPos)
{
    float localLightCount = uLocalLights[0].w;
    vec2 metric = vec2(0.0);
    if (localLightCount > 0.5) {
        metric = max(metric, evaluatePackedLocalLightMetrics(uLocalLights[1], uLocalLights[2], uLocalLights[3],
            uLocalLights[4], uLocalLights[5], uLocalLights[6], n, worldPos));
    }
    if (localLightCount > 1.5) {
        metric = max(metric, evaluatePackedLocalLightMetrics(uLocalLights[7], uLocalLights[8], uLocalLights[9],
            uLocalLights[10], uLocalLights[11], uLocalLights[12], n, worldPos));
    }
    if (localLightCount > 2.5) {
        metric = max(metric, evaluatePackedLocalLightMetrics(uLocalLights[13], uLocalLights[14], uLocalLights[15],
            uLocalLights[16], uLocalLights[17], uLocalLights[18], n, worldPos));
    }
    if (localLightCount > 3.5) {
        metric = max(metric, evaluatePackedLocalLightMetrics(uLocalLights[19], uLocalLights[20], uLocalLights[21],
            uLocalLights[22], uLocalLights[23], uLocalLights[24], n, worldPos));
    }
    return metric;
}

vec3 localLightHeatmap(float v)
{
    v = clamp(v, 0.0, 1.0);
    return mix(vec3(0.02, 0.04, 0.12), vec3(1.0, 0.82, 0.34), v);
}

// Keep the lighting result in HDR until exposure, bloom and the frame tone
// curve have run. Clamping here would make a 2x-lit surface exposed by 0.25
// resolve to 0.25 instead of the physically consistent 0.5.
vec3 prepareFrameShadedColor(vec3 rgb, float brightness)
{
    return max(rgb * max(brightness, 0.0), vec3(0.0));
}

vec3 applyFrameFogAndExposure(vec3 rgb, vec3 worldPos)
{
    vec3 outColor = max(rgb, vec3(0.0));
    vec4 cascadeDebug = directionalShadowCascadeDebugColor(worldPos);
    if (cascadeDebug.a > 0.5) {
        return cascadeDebug.rgb;
    }
    if (uLighting6.w > 0.5) {
        float fogT = clamp((distance(uCameraPos, worldPos) - uLighting7.x) * uLighting7.z, 0.0, 1.0);
        outColor = mix(outColor, uLighting6.rgb, fogT);
    }
    outColor = rbxApplyAtmosphere(
        outColor, worldPos, uCameraPos, uAtmosphereSunDirection);
    // A real frame target owns exposure, tone mapping, spatial bloom and
    // ColorCorrection. Keep material output linear HDR in that mode; alpha
    // composition still happens normally in the scene Canvas.
    if (uFramePostActive > 0.5) {
        return outColor;
    }
    float exposure = clamp(uLighting5.w, 0.03125, 32.0);
    outColor *= exposure;
    // Bloom is deliberately absent from the material fallback. A same-pixel
    // brightness boost is not bloom and made Bloom.Size meaningless.
    // Compatibility-only LDR fallback for GPUs without a float scene target:
    // preserve the established <=1 response. Above-white information cannot
    // survive an rgba8 target; capable GPUs use the frame resolver's monotonic
    // exponential shoulder instead.
    outColor = outColor
        / (vec3(1.0) + max(outColor - vec3(1.0), vec3(0.0)));
    float luma = dot(outColor, vec3(0.2126, 0.7152, 0.0722));
    outColor = mix(vec3(luma), outColor, 1.0 + clamp(uPostSaturation, -1.0, 4.0));
    outColor = (outColor - vec3(0.5)) * (1.0 + clamp(uPostContrast, -1.0, 4.0)) + vec3(0.5);
    outColor += vec3(clamp(uPostBrightness, -1.0, 1.0));
    outColor *= clamp(uColorCorrectionTint, vec3(0.0), vec3(4.0));
    return clamp(outColor, 0.0, 1.0);
}

vec3 previewFrameHdr(vec3 rgb, vec3 worldPos)
{
    vec3 outColor = max(rgb, vec3(0.0));
    vec4 cascadeDebug = directionalShadowCascadeDebugColor(worldPos);
    if (cascadeDebug.a > 0.5) {
        return cascadeDebug.rgb;
    }
    if (uLighting6.w > 0.5) {
        float fogT = clamp((distance(uCameraPos, worldPos) - uLighting7.x) * uLighting7.z, 0.0, 1.0);
        outColor = mix(outColor, uLighting6.rgb, fogT);
    }
    outColor = rbxApplyAtmosphere(
        outColor, worldPos, uCameraPos, uAtmosphereSunDirection);
    return clamp(outColor / (vec3(1.0) + outColor), 0.0, 1.0);
}

vec3 falseColorLuminance(vec3 rgb)
{
    float v = clamp(dot(rgb, vec3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
    if (v < 0.25) {
        return mix(vec3(0.02, 0.03, 0.12), vec3(0.0, 0.45, 0.90), v / 0.25);
    }
    if (v < 0.55) {
        return mix(vec3(0.0, 0.45, 0.90), vec3(0.20, 0.95, 0.55), (v - 0.25) / 0.30);
    }
    if (v < 0.82) {
        return mix(vec3(0.20, 0.95, 0.55), vec3(1.00, 0.78, 0.22), (v - 0.55) / 0.27);
    }
    return mix(vec3(1.00, 0.78, 0.22), vec3(1.0, 0.12, 0.08), (v - 0.82) / 0.18);
}

vec3 hsvToRgb(vec3 c)
{
    vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

float hueFromRgb(vec3 c)
{
    float mx = max(max(c.r, c.g), c.b);
    float mn = min(min(c.r, c.g), c.b);
    float d = mx - mn;
    if (d <= 0.00001) {
        return 0.0;
    }
    float h = 0.0;
    if (mx == c.r) {
        h = mod((c.g - c.b) / d, 6.0);
    } else if (mx == c.g) {
        h = ((c.b - c.r) / d) + 2.0;
    } else {
        h = ((c.r - c.g) / d) + 4.0;
    }
    return h / 6.0;
}

vec3 falseColorHue(vec3 rgb)
{
    float h = hueFromRgb(max(rgb, vec3(0.0)));
    float sat = clamp((max(max(rgb.r, rgb.g), rgb.b) - min(min(rgb.r, rgb.g), rgb.b)) * 3.0, 0.35, 1.0);
    return hsvToRgb(vec3(h, sat, 0.95));
}
]]

-- a depth bias is a small view-depth displacement (studs), not an NDC
-- displacement. Constant NDC bias grows quadratically in world space and can
-- pull a distant ground overlay through entire buildings. keep x/y/w unchanged
-- so this corrects depth ownership without moving the projected surface
-- Native effect geometry shares the material lighting packet. Geometry and
-- source alpha/emission remain owned by the persistent effect draw path
RBX._effect_lighting_glsl = LIGHTING_FRAME_GLSL

CAMERA_DEPTH_BIAS_GLSL = [[
vec4 applyCameraDepthBias(vec4 clipPos, mat4 projection, float bias)
{
    if (bias == 0.0) return clipPos;
    if (projection[2][3] != 0.0) {
        // Perspective depth = A + B / viewDepth. Reproject viewDepth-bias;
        // use the actual near/far coefficient B, including auto-clip changes.
        if (clipPos.w <= 0.0) return clipPos;
        float displacement = clamp(bias, -0.5 * clipPos.w, 0.5 * clipPos.w);
        clipPos.z += projection[3][2] * displacement / (clipPos.w - displacement);
    } else {
        // Orthographic depth is linear in view depth.
        clipPos.z -= abs(projection[2][2]) * bias * clipPos.w;
    }
    return clipPos;
}
]]

INSTANCED_SHADER = [[
uniform mat4 uViewRotationMatrix;
uniform mat4 uProjectionMatrix;
uniform float uDepthBias;
]] .. CAMERA_DEPTH_BIAS_GLSL .. [[
uniform vec3 uSunDirection;
uniform vec3 uSunColor;
uniform vec3 uSkyColor;
uniform vec3 uGroundColor;
uniform vec3 uCameraPos;
uniform float uAmbient;
uniform float uDiffuseStrength;
uniform float uSpecularStrength;
uniform float uRimStrength;
]] .. LIGHTING_FRAME_GLSL .. [[

varying vec3 vNormal;
varying vec4 vColor;
varying float vNonUnitInstanceAlpha;
varying vec3 vWorldPos;
varying float vReflectance;
varying float vContactAO;

#ifdef VERTEX
attribute vec3 VertexNormal;
attribute vec3 InstancePosition;
attribute vec3 InstanceRight;
attribute vec3 InstanceUp;
attribute vec3 InstanceBack;
attribute vec3 InstanceSize;
attribute vec4 InstanceColor;
attribute float InstanceReflectance;
attribute vec4 InstanceContactAO;

vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vec3 localPos = vec3(
        vertex_position.x * InstanceSize.x,
        vertex_position.y * InstanceSize.y,
        vertex_position.z * InstanceSize.z
    );

    vec3 worldPos = InstancePosition
        + (InstanceRight * localPos.x)
        + (InstanceUp * localPos.y)
        + (InstanceBack * localPos.z);

    // Normals are covectors.  The instance position transform is R*S, so the
    // matching normal transform is inverse-transpose(R*S).  InstanceRight/Up/Back
    // are an orthonormal R, reducing that to R * (normal / size).  Axis-aligned
    // Block normals are unchanged after normalization; sloped and curved primitive
    // normals are not.
    vec3 safeSize = vec3(
        InstanceSize.x >= 0.0 ? max(InstanceSize.x, 1e-6) : min(InstanceSize.x, -1e-6),
        InstanceSize.y >= 0.0 ? max(InstanceSize.y, 1e-6) : min(InstanceSize.y, -1e-6),
        InstanceSize.z >= 0.0 ? max(InstanceSize.z, 1e-6) : min(InstanceSize.z, -1e-6));
    vec3 scaledNormal = VertexNormal / safeSize;
    vec3 worldNormal = (InstanceRight * scaledNormal.x)
        + (InstanceUp * scaledNormal.y)
        + (InstanceBack * scaledNormal.z);

    vNormal = normalize(worldNormal);
    vWorldPos = worldPos;
    vColor = InstanceColor;
    // This attribute is constant over every vertex of each instance. An exact
    // zero survives interpolation; interpolating the authored one can round below
    // one on a perspective triangle. Keep the original varying for nonunit alpha.
    vNonUnitInstanceAlpha = InstanceColor.a == 1.0 ? 0.0 : 1.0;
    vReflectance = clamp(InstanceReflectance, 0.0, 1.0);
    // Contact buckets are authored in the primitive's unscaled local frame.
    // Keep this selection identical to the CPU-baked static path; scale affects
    // the lighting normal, but it must not reclassify top/bottom/side contact.
    vContactAO = selectContactAO(VertexNormal, InstanceContactAO);

    vec4 clipPos = uProjectionMatrix * uViewRotationMatrix * vec4(worldPos - uCameraPos, 1.0);
    clipPos = applyCameraDepthBias(clipPos, uProjectionMatrix, uDepthBias);
    return clipPos;
}
#endif

#ifdef PIXEL
vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
{
    float instanceAlpha = vNonUnitInstanceAlpha == 0.0 ? 1.0 : vColor.a;
    vec3 n = normalize(vNormal);
    vec3 base = clamp(vColor.rgb, 0.0, 1.0);
    float reflectance = clamp(vReflectance, 0.0, 1.0);

    vec3 lightDir = normalize(uSunDirection);
    float ndotl = max(dot(n, lightDir), 0.0);

    float contactFill = computeContactFill(vContactAO);
    vec3 coolAmbientTerm = computeFrameCoolAmbientTerm(n) * contactFill;
    vec3 environmentTerm = computeFrameEnvironmentTerm(n) * contactFill;
    vec3 ambientTerm = coolAmbientTerm + environmentTerm;
    float directionalShadow = computeDirectionalShadow(vWorldPos, n);
    vec3 diffuseTerm = computeFrameDiffuseTerm(n) * directionalShadow;
    vec3 localTerm = computeLocalLightContribution(n, vWorldPos);

    if (uLightingDebugView > 0.5 && uLightingDebugView < 1.5) {
        return vec4(base, instanceAlpha);
    }
    if (uLightingDebugView > 1.5 && uLightingDebugView < 2.5) {
        return vec4(applyFrameFogAndExposure(base * (ambientTerm + diffuseTerm), vWorldPos), instanceAlpha);
    }
    if (uLightingDebugView > 2.5 && uLightingDebugView < 3.5) {
        return vec4(applyFrameFogAndExposure(base * localTerm, vWorldPos), instanceAlpha);
    }
    if (uLightingDebugView > 3.5 && uLightingDebugView < 4.5) {
        vec2 localMetric = computeLocalLightMetrics(n, vWorldPos);
        return vec4(localLightHeatmap(localMetric.x), instanceAlpha);
    }
    if (uLightingDebugView > 4.5 && uLightingDebugView < 5.5) {
        vec2 localMetric = computeLocalLightMetrics(n, vWorldPos);
        return vec4(vec3(localMetric.y), instanceAlpha);
    }
    if (uLightingDebugView > 5.5 && uLightingDebugView < 6.5) {
        return vec4(clamp(base * localTerm, 0.0, 1.0), instanceAlpha);
    }
    if (uLightingDebugView > 6.5 && uLightingDebugView < 7.5) {
        return vec4(clamp(n * 0.5 + 0.5, 0.0, 1.0), instanceAlpha);
    }
    if (uLightingDebugView > 7.5 && uLightingDebugView < 8.5) {
        return vec4(vec3(ndotl), instanceAlpha);
    }
    if (uLightingDebugView > 8.5 && uLightingDebugView < 9.5) {
        return vec4(vec3(computeFrameSkyVisibility(n)), instanceAlpha);
    }
    if (uLightingDebugView > 9.5 && uLightingDebugView < 10.5) {
        return vec4(vec3(vContactAO), instanceAlpha);
    }
    if (uLightingDebugView > 10.5 && uLightingDebugView < 11.5) {
        return vec4(applyFrameFogAndExposure(base * coolAmbientTerm, vWorldPos), instanceAlpha);
    }
    if (uLightingDebugView > 11.5 && uLightingDebugView < 12.5) {
        return vec4(applyFrameFogAndExposure(base * environmentTerm, vWorldPos), instanceAlpha);
    }
    if (uLightingDebugView > 12.5 && uLightingDebugView < 13.5) {
        return vec4(applyFrameFogAndExposure(base * diffuseTerm, vWorldPos), instanceAlpha);
    }
    if (uLightingDebugView > 13.5 && uLightingDebugView < 14.5) {
        return vec4(mix(uAtmosphereColor, uSkyColor, 0.35), instanceAlpha);
    }

    vec3 viewDir = normalize(uCameraPos - vWorldPos);
    vec3 halfDir = normalize(lightDir + viewDir);
    float shininess = mix(24.0, 128.0, reflectance);
    float spec = pow(max(dot(n, halfDir), 0.0), shininess)
        * uSpecularStrength * (1.0 + reflectance * 2.0)
        * directionalShadow;

    float fresnel = pow(1.0 - max(dot(n, viewDir), 0.0), 2.0) * uRimStrength * (1.0 + reflectance * 1.2);

    vec3 reflect_color = mix(uSkyColor, uSunColor, uReflectionSunWeight) * (reflectance * 0.22 * uEnvironmentSpecularScale);
    vec3 lit = base * (ambientTerm + diffuseTerm + localTerm) + (uSunColor * spec) + (uSkyColor * (fresnel * 0.15)) + reflect_color;
    if (uLightingDebugView > 14.5 && uLightingDebugView < 15.5) {
        return vec4(previewFrameHdr(lit, vWorldPos), instanceAlpha);
    }
    if (uLightingDebugView > 15.5 && uLightingDebugView < 16.5) {
        return vec4(falseColorLuminance(applyFrameFogAndExposure(lit, vWorldPos)), instanceAlpha);
    }
    if (uLightingDebugView > 16.5 && uLightingDebugView < 17.5) {
        return vec4(falseColorHue(applyFrameFogAndExposure(lit, vWorldPos)), instanceAlpha);
    }
    // The previous brightness floor lifted shadow faces toward 0.4-0.5
    // of the base color, which crushed Roblox-style directional contrast.
    // Removed entirely — ambient + directional + local lights are the
    // only sources of brightness.
    return vec4(applyFrameFogAndExposure(lit, vWorldPos), instanceAlpha);
}
#endif
]]

-- static primitive meshes normally contain world-space vertices.  Dynamic
-- transparent primitives retain that mesh and supply a rigid delta instead of
-- reallocating and re-uploading it on every CFrame update.  keep this separate
-- from the textured helper below because this vertex format has no tangents
RBX._static_rigid_mesh_glsl = [[
uniform float uRigidEnabled;
uniform vec4 uRigidRows[3];
vec3 rbxStaticRigidPoint(vec3 p) {
    if (uRigidEnabled < 0.5) return p;
    vec4 q = vec4(p, 1.0);
    return vec3(dot(uRigidRows[0], q), dot(uRigidRows[1], q), dot(uRigidRows[2], q));
}
vec3 rbxStaticRigidDirection(vec3 d) {
    if (uRigidEnabled < 0.5) return d;
    return vec3(dot(uRigidRows[0].xyz, d), dot(uRigidRows[1].xyz, d), dot(uRigidRows[2].xyz, d));
}
]]

STATIC_SHADER = RBX._static_rigid_mesh_glsl .. [[
uniform mat4 uViewRotationMatrix;
uniform mat4 uProjectionMatrix;
uniform bool uVertexAlphaIsOne;
uniform float uDepthBias;
]] .. CAMERA_DEPTH_BIAS_GLSL .. [[
uniform vec3 uSunDirection;
uniform vec3 uSunColor;
uniform vec3 uSkyColor;
uniform vec3 uGroundColor;
uniform vec3 uCameraPos;
uniform float uAmbient;
uniform float uDiffuseStrength;
uniform float uSpecularStrength;
uniform float uRimStrength;
]] .. LIGHTING_FRAME_GLSL .. [[

varying vec3 vNormal;
varying vec4 vColor;
varying vec3 vWorldPos;
varying float vReflectance;
varying float vContactAO;

#ifdef VERTEX
attribute vec3 VertexNormal;
attribute float VertexReflectance;
attribute float VertexContactAO;

vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vec3 worldPos = rbxStaticRigidPoint(vertex_position.xyz);
    vNormal = normalize(rbxStaticRigidDirection(VertexNormal));
    vWorldPos = worldPos;
    vColor = VertexColor;
    vReflectance = clamp(VertexReflectance, 0.0, 1.0);
    vContactAO = clamp(VertexContactAO, 0.0, 1.0);
    vec4 clipPos = uProjectionMatrix * uViewRotationMatrix * vec4(worldPos - uCameraPos, 1.0);
    clipPos = applyCameraDepthBias(clipPos, uProjectionMatrix, uDepthBias);
    return clipPos;
}
#endif

#ifdef PIXEL
vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
{
    float vertexAlpha = uVertexAlphaIsOne ? 1.0 : vColor.a;
    vec3 n = normalize(vNormal);
    vec3 base = clamp(vColor.rgb, 0.0, 1.0);
    float reflectance = clamp(vReflectance, 0.0, 1.0);

    vec3 lightDir = normalize(uSunDirection);
    float ndotl = max(dot(n, lightDir), 0.0);

    float contactFill = computeContactFill(vContactAO);
    vec3 coolAmbientTerm = computeFrameCoolAmbientTerm(n) * contactFill;
    vec3 environmentTerm = computeFrameEnvironmentTerm(n) * contactFill;
    vec3 ambientTerm = coolAmbientTerm + environmentTerm;
    float directionalShadow = computeDirectionalShadow(vWorldPos, n);
    vec3 diffuseTerm = computeFrameDiffuseTerm(n) * directionalShadow;
    vec3 localTerm = computeLocalLightContribution(n, vWorldPos);

    if (uLightingDebugView > 0.5 && uLightingDebugView < 1.5) {
        return vec4(base, vertexAlpha);
    }
    if (uLightingDebugView > 1.5 && uLightingDebugView < 2.5) {
        return vec4(applyFrameFogAndExposure(base * (ambientTerm + diffuseTerm), vWorldPos), vertexAlpha);
    }
    if (uLightingDebugView > 2.5 && uLightingDebugView < 3.5) {
        return vec4(applyFrameFogAndExposure(base * localTerm, vWorldPos), vertexAlpha);
    }
    if (uLightingDebugView > 3.5 && uLightingDebugView < 4.5) {
        vec2 localMetric = computeLocalLightMetrics(n, vWorldPos);
        return vec4(localLightHeatmap(localMetric.x), vertexAlpha);
    }
    if (uLightingDebugView > 4.5 && uLightingDebugView < 5.5) {
        vec2 localMetric = computeLocalLightMetrics(n, vWorldPos);
        return vec4(vec3(localMetric.y), vertexAlpha);
    }
    if (uLightingDebugView > 5.5 && uLightingDebugView < 6.5) {
        return vec4(clamp(base * localTerm, 0.0, 1.0), vertexAlpha);
    }
    if (uLightingDebugView > 6.5 && uLightingDebugView < 7.5) {
        return vec4(clamp(n * 0.5 + 0.5, 0.0, 1.0), vertexAlpha);
    }
    if (uLightingDebugView > 7.5 && uLightingDebugView < 8.5) {
        return vec4(vec3(ndotl), vertexAlpha);
    }
    if (uLightingDebugView > 8.5 && uLightingDebugView < 9.5) {
        return vec4(vec3(computeFrameSkyVisibility(n)), vertexAlpha);
    }
    if (uLightingDebugView > 9.5 && uLightingDebugView < 10.5) {
        return vec4(vec3(vContactAO), vertexAlpha);
    }
    if (uLightingDebugView > 10.5 && uLightingDebugView < 11.5) {
        return vec4(applyFrameFogAndExposure(base * coolAmbientTerm, vWorldPos), vertexAlpha);
    }
    if (uLightingDebugView > 11.5 && uLightingDebugView < 12.5) {
        return vec4(applyFrameFogAndExposure(base * environmentTerm, vWorldPos), vertexAlpha);
    }
    if (uLightingDebugView > 12.5 && uLightingDebugView < 13.5) {
        return vec4(applyFrameFogAndExposure(base * diffuseTerm, vWorldPos), vertexAlpha);
    }
    if (uLightingDebugView > 13.5 && uLightingDebugView < 14.5) {
        return vec4(mix(uAtmosphereColor, uSkyColor, 0.35), vertexAlpha);
    }

    vec3 viewDir = normalize(uCameraPos - vWorldPos);
    vec3 halfDir = normalize(lightDir + viewDir);
    float shininess = mix(24.0, 128.0, reflectance);
    float spec = pow(max(dot(n, halfDir), 0.0), shininess)
        * uSpecularStrength * (1.0 + reflectance * 2.0)
        * directionalShadow;

    float fresnel = pow(1.0 - max(dot(n, viewDir), 0.0), 2.0) * uRimStrength * (1.0 + reflectance * 1.2);

    vec3 reflect_color = mix(uSkyColor, uSunColor, uReflectionSunWeight) * (reflectance * 0.22 * uEnvironmentSpecularScale);
    vec3 lit = base * (ambientTerm + diffuseTerm + localTerm) + (uSunColor * spec) + (uSkyColor * (fresnel * 0.15)) + reflect_color;
    if (uLightingDebugView > 14.5 && uLightingDebugView < 15.5) {
        return vec4(previewFrameHdr(lit, vWorldPos), vertexAlpha);
    }
    if (uLightingDebugView > 15.5 && uLightingDebugView < 16.5) {
        return vec4(falseColorLuminance(applyFrameFogAndExposure(lit, vWorldPos)), vertexAlpha);
    }
    if (uLightingDebugView > 16.5 && uLightingDebugView < 17.5) {
        return vec4(falseColorHue(applyFrameFogAndExposure(lit, vWorldPos)), vertexAlpha);
    }
    // The previous brightness floor lifted shadow faces toward 0.4-0.5
    // of the base color, which crushed Roblox-style directional contrast.
    // Removed entirely — ambient + directional + local lights are the
    // only sources of brightness.
    return vec4(applyFrameFogAndExposure(lit, vWorldPos), vertexAlpha);
}
#endif
]]

FAST_INSTANCED_SHADER = [[
uniform mat4 uViewRotationMatrix;
uniform mat4 uProjectionMatrix;
uniform vec3 uSunDirection;
uniform vec3 uSunColor;
uniform vec3 uSkyColor;
uniform vec3 uGroundColor;
uniform vec3 uCameraPos;
uniform float uAmbient;
uniform float uDiffuseStrength;
uniform float uDepthBias;
]] .. CAMERA_DEPTH_BIAS_GLSL .. [[
]] .. LIGHTING_FRAME_GLSL .. [[

varying vec4 vColor;
varying vec3 vWorldPos;
varying vec3 vShadowNormal;
varying vec3 vDirectionalColor;

#ifdef VERTEX
attribute vec3 VertexNormal;
attribute vec3 InstancePosition;
attribute vec3 InstanceRight;
attribute vec3 InstanceUp;
attribute vec3 InstanceBack;
attribute vec3 InstanceSize;
attribute vec4 InstanceColor;
attribute vec4 InstanceContactAO;

vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vec3 localPos = vec3(
        vertex_position.x * InstanceSize.x,
        vertex_position.y * InstanceSize.y,
        vertex_position.z * InstanceSize.z
    );

    vec3 worldPos = InstancePosition
        + (InstanceRight * localPos.x)
        + (InstanceUp * localPos.y)
        + (InstanceBack * localPos.z);

    vec3 safeSize = vec3(
        InstanceSize.x >= 0.0 ? max(InstanceSize.x, 1e-6) : min(InstanceSize.x, -1e-6),
        InstanceSize.y >= 0.0 ? max(InstanceSize.y, 1e-6) : min(InstanceSize.y, -1e-6),
        InstanceSize.z >= 0.0 ? max(InstanceSize.z, 1e-6) : min(InstanceSize.z, -1e-6));
    vec3 scaledNormal = VertexNormal / safeSize;
    vec3 n = normalize((InstanceRight * scaledNormal.x)
        + (InstanceUp * scaledNormal.y)
        + (InstanceBack * scaledNormal.z));
    float ndotl = max(dot(n, uSunDirection), 0.0);
    // Match the baked path's part-local contact classification.
    float contactAO = selectContactAO(VertexNormal, InstanceContactAO);
    float contactFill = computeContactFill(contactAO);
    vec3 coolAmbientTerm = computeFrameCoolAmbientTerm(n) * contactFill;
    vec3 environmentTerm = computeFrameEnvironmentTerm(n) * contactFill;
    vec3 ambientTerm = coolAmbientTerm + environmentTerm;
    vec3 diffuseTerm = computeFrameDiffuseTerm(n);
    vec3 localTerm = computeLocalLightContribution(n, worldPos);
    vec3 baseColor = clamp(InstanceColor.rgb, 0.0, 1.0);
    vec3 litColor = baseColor * (ambientTerm + diffuseTerm + localTerm);
    vShadowNormal = n;
    vDirectionalColor = baseColor * diffuseTerm;
    if (uLightingDebugView > 0.5 && uLightingDebugView < 1.5) {
        litColor = baseColor;
    } else if (uLightingDebugView > 1.5 && uLightingDebugView < 2.5) {
        litColor = baseColor * (ambientTerm + diffuseTerm);
    } else if (uLightingDebugView > 2.5 && uLightingDebugView < 3.5) {
        litColor = baseColor * localTerm;
    } else if (uLightingDebugView > 6.5 && uLightingDebugView < 7.5) {
        litColor = clamp(n * 0.5 + 0.5, 0.0, 1.0);
    } else if (uLightingDebugView > 7.5 && uLightingDebugView < 8.5) {
        litColor = vec3(ndotl);
    } else if (uLightingDebugView > 8.5 && uLightingDebugView < 9.5) {
        litColor = vec3(computeFrameSkyVisibility(n));
    } else if (uLightingDebugView > 9.5 && uLightingDebugView < 10.5) {
        litColor = vec3(contactAO);
    } else if (uLightingDebugView > 10.5 && uLightingDebugView < 11.5) {
        litColor = baseColor * coolAmbientTerm;
    } else if (uLightingDebugView > 11.5 && uLightingDebugView < 12.5) {
        litColor = baseColor * environmentTerm;
    } else if (uLightingDebugView > 12.5 && uLightingDebugView < 13.5) {
        litColor = baseColor * diffuseTerm;
    } else if (uLightingDebugView > 13.5 && uLightingDebugView < 14.5) {
        litColor = mix(uAtmosphereColor, uSkyColor, 0.35);
    }
    if (!(uLightingDebugView < 0.5
        || (uLightingDebugView > 1.5 && uLightingDebugView < 2.5)
        || (uLightingDebugView > 12.5 && uLightingDebugView < 13.5))) {
        vDirectionalColor = vec3(0.0);
    }
    vWorldPos = worldPos;
    // No floor — see note in textured shader.
    vColor = vec4(litColor, InstanceColor.a);

    vec4 clipPos = uProjectionMatrix * uViewRotationMatrix * vec4(worldPos - uCameraPos, 1.0);
    clipPos = applyCameraDepthBias(clipPos, uProjectionMatrix, uDepthBias);
    return clipPos;
}
#endif

#ifdef PIXEL
vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
{
    float directionalShadow = computeDirectionalShadow(
        vWorldPos, normalize(vShadowNormal));
    vec3 shadowedColor = vColor.rgb
        - vDirectionalColor * (1.0 - directionalShadow);
    if (uLightingDebugView > 14.5 && uLightingDebugView < 15.5) {
        return vec4(previewFrameHdr(shadowedColor, vWorldPos), vColor.a);
    }
    if (uLightingDebugView > 15.5 && uLightingDebugView < 16.5) {
        return vec4(falseColorLuminance(applyFrameFogAndExposure(shadowedColor, vWorldPos)), vColor.a);
    }
    if (uLightingDebugView > 16.5 && uLightingDebugView < 17.5) {
        return vec4(falseColorHue(applyFrameFogAndExposure(shadowedColor, vWorldPos)), vColor.a);
    }
    return vec4(applyFrameFogAndExposure(shadowedColor, vWorldPos), vColor.a);
}
#endif
]]

FAST_STATIC_SHADER = RBX._static_rigid_mesh_glsl .. [[
uniform mat4 uViewRotationMatrix;
uniform mat4 uProjectionMatrix;
uniform vec3 uSunDirection;
uniform vec3 uSunColor;
uniform vec3 uSkyColor;
uniform vec3 uGroundColor;
uniform vec3 uCameraPos;
uniform float uAmbient;
uniform float uDiffuseStrength;
uniform bool uVertexAlphaIsOne;
uniform float uDepthBias;
]] .. CAMERA_DEPTH_BIAS_GLSL .. [[
]] .. LIGHTING_FRAME_GLSL .. [[

varying vec4 vColor;
varying vec3 vWorldPos;
varying vec3 vShadowNormal;
varying vec3 vDirectionalColor;

#ifdef VERTEX
attribute vec3 VertexNormal;
attribute float VertexContactAO;

vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vec3 worldPos = rbxStaticRigidPoint(vertex_position.xyz);
    vec3 n = normalize(rbxStaticRigidDirection(VertexNormal));
    float ndotl = max(dot(n, uSunDirection), 0.0);
    float contactAO = clamp(VertexContactAO, 0.0, 1.0);
    float contactFill = computeContactFill(contactAO);
    vec3 coolAmbientTerm = computeFrameCoolAmbientTerm(n) * contactFill;
    vec3 environmentTerm = computeFrameEnvironmentTerm(n) * contactFill;
    vec3 ambientTerm = coolAmbientTerm + environmentTerm;
    vec3 diffuseTerm = computeFrameDiffuseTerm(n);
    vec3 localTerm = computeLocalLightContribution(n, worldPos);
    vec3 baseColor = clamp(VertexColor.rgb, 0.0, 1.0);
    vec3 litColor = baseColor * (ambientTerm + diffuseTerm + localTerm);
    vShadowNormal = n;
    vDirectionalColor = baseColor * diffuseTerm;
    if (uLightingDebugView > 0.5 && uLightingDebugView < 1.5) {
        litColor = baseColor;
    } else if (uLightingDebugView > 1.5 && uLightingDebugView < 2.5) {
        litColor = baseColor * (ambientTerm + diffuseTerm);
    } else if (uLightingDebugView > 2.5 && uLightingDebugView < 3.5) {
        litColor = baseColor * localTerm;
    } else if (uLightingDebugView > 6.5 && uLightingDebugView < 7.5) {
        litColor = clamp(n * 0.5 + 0.5, 0.0, 1.0);
    } else if (uLightingDebugView > 7.5 && uLightingDebugView < 8.5) {
        litColor = vec3(ndotl);
    } else if (uLightingDebugView > 8.5 && uLightingDebugView < 9.5) {
        litColor = vec3(computeFrameSkyVisibility(n));
    } else if (uLightingDebugView > 9.5 && uLightingDebugView < 10.5) {
        litColor = vec3(contactAO);
    } else if (uLightingDebugView > 10.5 && uLightingDebugView < 11.5) {
        litColor = baseColor * coolAmbientTerm;
    } else if (uLightingDebugView > 11.5 && uLightingDebugView < 12.5) {
        litColor = baseColor * environmentTerm;
    } else if (uLightingDebugView > 12.5 && uLightingDebugView < 13.5) {
        litColor = baseColor * diffuseTerm;
    } else if (uLightingDebugView > 13.5 && uLightingDebugView < 14.5) {
        litColor = mix(uAtmosphereColor, uSkyColor, 0.35);
    }
    if (!(uLightingDebugView < 0.5
        || (uLightingDebugView > 1.5 && uLightingDebugView < 2.5)
        || (uLightingDebugView > 12.5 && uLightingDebugView < 13.5))) {
        vDirectionalColor = vec3(0.0);
    }
    vWorldPos = worldPos;
    // No floor — see note in textured shader.
    vColor = vec4(litColor, VertexColor.a);
    vec4 clipPos = uProjectionMatrix * uViewRotationMatrix * vec4(worldPos - uCameraPos, 1.0);
    clipPos = applyCameraDepthBias(clipPos, uProjectionMatrix, uDepthBias);
    return clipPos;
}
#endif

#ifdef PIXEL
vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
{
    float vertexAlpha = uVertexAlphaIsOne ? 1.0 : vColor.a;
    float directionalShadow = computeDirectionalShadow(
        vWorldPos, normalize(vShadowNormal));
    vec3 shadowedColor = vColor.rgb
        - vDirectionalColor * (1.0 - directionalShadow);
    if (uLightingDebugView > 14.5 && uLightingDebugView < 15.5) {
        return vec4(previewFrameHdr(shadowedColor, vWorldPos), vertexAlpha);
    }
    if (uLightingDebugView > 15.5 && uLightingDebugView < 16.5) {
        return vec4(falseColorLuminance(applyFrameFogAndExposure(shadowedColor, vWorldPos)), vertexAlpha);
    }
    if (uLightingDebugView > 16.5 && uLightingDebugView < 17.5) {
        return vec4(falseColorHue(applyFrameFogAndExposure(shadowedColor, vWorldPos)), vertexAlpha);
    }
    return vec4(applyFrameFogAndExposure(shadowedColor, vWorldPos), vertexAlpha);
}
#endif
]]

-- Rigid owned chunks keep their baked reference geometry resident. this
-- vertex-only pose transforms position, normal and tangent together, UVs,
-- material coverage and alpha retain their authored values. zero is identity
-- so direct shader users keep the existing contract until a pose is sent
RBX._rigid_mesh_glsl = [[
uniform float uRigidEnabled;
uniform vec4 uRigidRows[3];
vec3 rbxRigidPoint(vec3 p) {
    if (uRigidEnabled < 0.5) return p;
    vec4 q = vec4(p, 1.0);
    return vec3(dot(uRigidRows[0], q), dot(uRigidRows[1], q), dot(uRigidRows[2], q));
}
vec3 rbxRigidDirection(vec3 d) {
    if (uRigidEnabled < 0.5) return d;
    return vec3(dot(uRigidRows[0].xyz, d), dot(uRigidRows[1].xyz, d), dot(uRigidRows[2].xyz, d));
}
vec3 rbxRigidNormal(vec3 n) {
    if (uRigidEnabled < 1.5) return rbxRigidDirection(n);
    vec3 a=uRigidRows[0].xyz, b=uRigidRows[1].xyz, c=uRigidRows[2].xyz;
    // Inverse transpose, including signed/nonuniform retained scale.
    return vec3(dot(cross(b,c),n),dot(cross(c,a),n),dot(cross(a,b),n))/dot(a,cross(b,c));
}
]]

TEXTURED_SHADER = RBX._rigid_mesh_glsl .. [[
uniform mat4 uViewRotationMatrix;
uniform mat4 uProjectionMatrix;
uniform vec3 uSunDirection;
uniform vec3 uSunColor;
uniform vec3 uSkyColor;
uniform vec3 uGroundColor;
uniform vec3 uCameraPos;
uniform float uAmbient;
uniform float uDiffuseStrength;
uniform float uSpecularStrength;
uniform float uRimStrength;
uniform float uUseMaterialMaps;
// x=roughness, y=metalness, z=linear-HDR emissive multiplier,
// w=minimum transparency imposed by the BasePart material.
uniform vec4 uMaterialSurface;
// Actual data-map presence. White/black fallback textures must not erase the
// authoritative scalar semantics when an asset family omits a channel.
uniform vec2 uMaterialMapMask;
uniform float uUseTexturedLighting;
uniform float uUseNormalMap;
uniform float uDetailNormalMix;
uniform float uDetailContrast;
uniform float uTextureColorMix;
uniform float uFlipV;
uniform float uFlipU;
uniform float uDepthBias;
]] .. CAMERA_DEPTH_BIAS_GLSL .. [[
uniform float uIgnoreTextureAlpha;
uniform bool uVertexAlphaIsOne;
uniform float uLightInfluence;
uniform float uBrightness;
uniform float uMeshDebugMode;
uniform float uUseSurfaceAppearance;
uniform float uUseMeshTextureLayer;
extern Image uMeshTextureLayer;
varying vec2 vMeshTextureUV;
varying vec3 vMeshTextureTint;
uniform float uUseMaterialVariant;
uniform float uSurfaceAlphaMode;
uniform float uSurfaceColorMapActive;
uniform vec3 uSurfaceColor;
uniform float uSurfaceCutoutThreshold;
uniform float uSurfaceEmissiveStrength;
uniform vec3 uSurfaceEmissiveTint;
]] .. LIGHTING_FRAME_GLSL .. [[
extern Image uNormalMap;
extern Image uDetailNormalMap;
extern Image uRoughnessMap;
extern Image uMetalnessMap;
extern Image uEmissiveMap;

varying vec3 vNormal;
varying vec4 vColor;
varying vec3 vWorldPos;
varying float vReflectance;
varying vec3 vTangent;
varying vec3 vBitangent;
varying float vContactAO;

#ifdef VERTEX
attribute vec3 VertexNormal;
attribute vec3 VertexTangent;
attribute vec3 VertexBitangent;
attribute float VertexReflectance;
attribute float VertexContactAO;
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vec3 worldNormal = normalize(rbxRigidNormal(VertexNormal));
    vec3 worldPos = rbxRigidPoint(vertex_position.xyz);
    vNormal = worldNormal;
    vWorldPos = worldPos;
    vColor = VertexColor;
    vReflectance = clamp(VertexReflectance, 0.0, 1.0);
    vTangent = rbxRigidDirection(VertexTangent);
    vBitangent = rbxRigidDirection(VertexBitangent);
    vMeshTextureUV = VertexTangent.xy;
    vMeshTextureTint = VertexBitangent;
    if (uUseMeshTextureLayer > 0.5) {
        vTangent = vec3(0.0);
        vBitangent = vec3(0.0);
    }
    vContactAO = clamp(VertexContactAO, 0.0, 1.0);
    vec4 clipPos = uProjectionMatrix * uViewRotationMatrix
        * vec4(worldPos - uCameraPos, 1.0);
    clipPos = applyCameraDepthBias(clipPos, uProjectionMatrix, uDepthBias);
    return clipPos;
}
#endif

#ifdef PIXEL
vec3 decodeNormal(vec4 sampleColor)
{
    vec3 normal = sampleColor.rgb * 2.0 - 1.0;
    return normalize(vec3(normal.xy, max(normal.z, 0.0001)));
}

vec3 getNormalWithStrength(vec3 normal, float multiplier)
{
    float theta = atan(normal.x, normal.y);
    float phi = acos(clamp(normal.z, -1.0, 1.0)) * max(multiplier, 0.0);
    float phiSin = sin(phi);
    return normalize(vec3(
        sin(theta) * phiSin,
        cos(theta) * phiSin,
        cos(phi)
    ));
}

vec3 combineDetailNormals(vec3 primary, vec3 secondary, float multiplier)
{
    vec3 base = normalize(primary);
    vec3 detail = getNormalWithStrength(normalize(secondary), multiplier);

    base += vec3(0.0, 0.0, 1.0);
    detail *= vec3(-1.0, -1.0, 1.0);

    return normalize((base / max(base.z, 0.0001)) * dot(base, detail) - detail);
}

mat3 buildNormalBasis(vec3 worldNormal, vec3 worldPos, vec2 uv, vec3 tangentHint, vec3 bitangentHint)
{
    float tangentHintLenSq = dot(tangentHint, tangentHint);
    float bitangentHintLenSq = dot(bitangentHint, bitangentHint);
    if (tangentHintLenSq > 0.000001 && bitangentHintLenSq > 0.000001) {
        if (uFlipU > 0.5) {
            tangentHint *= -1.0;
        }
        if (uFlipV > 0.5) {
            bitangentHint *= -1.0;
        }
        vec3 tangent = tangentHint - worldNormal * dot(worldNormal, tangentHint);
        float tangentLenSq = dot(tangent, tangent);
        if (tangentLenSq > 0.000001) {
            tangent *= inversesqrt(tangentLenSq);
            vec3 bitangent = bitangentHint
                - worldNormal * dot(worldNormal, bitangentHint)
                - tangent * dot(tangent, bitangentHint);
            float bitangentLenSq = dot(bitangent, bitangent);
            if (bitangentLenSq > 0.000001) {
                bitangent *= inversesqrt(bitangentLenSq);
                if (dot(cross(tangent, bitangent), worldNormal) < 0.0) {
                    bitangent *= -1.0;
                }
                return mat3(tangent, bitangent, worldNormal);
            }
        }
    }

    vec3 dp1 = dFdx(worldPos);
    vec3 dp2 = dFdy(worldPos);
    vec2 duv1 = dFdx(uv);
    vec2 duv2 = dFdy(uv);

    vec3 dp2perp = cross(dp2, worldNormal);
    vec3 dp1perp = cross(worldNormal, dp1);
    vec3 tangent = dp2perp * duv1.x + dp1perp * duv2.x;
    vec3 bitangent = dp2perp * duv1.y + dp1perp * duv2.y;

    float tangentLenSq = dot(tangent, tangent);
    float bitangentLenSq = dot(bitangent, bitangent);
    if (tangentLenSq <= 0.000001 || bitangentLenSq <= 0.000001) {
        vec3 axis = abs(worldNormal.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
        tangent = normalize(cross(axis, worldNormal));
        bitangent = normalize(cross(worldNormal, tangent));
        return mat3(tangent, bitangent, worldNormal);
    }

    float invMax = inversesqrt(max(tangentLenSq, bitangentLenSq));
    tangent *= invMax;
    bitangent *= invMax;
    return mat3(tangent, bitangent, worldNormal);
}

vec3 sampleCombinedNormal(vec2 uv)
{
    vec3 primary = decodeNormal(Texel(uNormalMap, uv));
    if (uDetailNormalMix <= 0.0001) {
        return primary;
    }

    vec3 detail = decodeNormal(Texel(uDetailNormalMap, uv));
    return combineDetailNormals(primary, detail, uDetailNormalMix);
}

vec3 applyTextureDetailContrast(vec3 color)
{
    return clamp((color - 0.5) * max(uDetailContrast, 0.0) + 0.5, 0.0, 1.0);
}

float surfaceDistributionGGX(vec3 n, vec3 h, float roughness)
{
    float a = roughness * roughness;
    float a2 = a * a;
    float ndoth = max(dot(n, h), 0.0);
    float ndoth2 = ndoth * ndoth;
    float denominator = ndoth2 * (a2 - 1.0) + 1.0;
    return a2 / max(3.14159265 * denominator * denominator, 0.000001);
}

float surfaceGeometrySchlickGGX(float ndotv, float roughness)
{
    float r = roughness + 1.0;
    float k = (r * r) * 0.125;
    return ndotv / max(ndotv * (1.0 - k) + k, 0.000001);
}

float surfaceGeometrySmith(vec3 n, vec3 v, vec3 l, float roughness)
{
    return surfaceGeometrySchlickGGX(max(dot(n, v), 0.0), roughness)
        * surfaceGeometrySchlickGGX(max(dot(n, l), 0.0), roughness);
}

vec3 surfaceFresnelSchlick(float cosTheta, vec3 f0)
{
    return f0 + (vec3(1.0) - f0)
        * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

vec3 surfaceFresnelSchlickRoughness(
    float cosTheta, vec3 f0, float roughness)
{
    return f0 + (max(vec3(1.0 - roughness), f0) - f0)
        * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

// SurfaceAppearance needs the direction of every selected local light so its
// GGX lobe can follow the real source instead of treating local radiance as a
// diffuse-only ambient term. Keep this evaluator's source projection, range
// curve, cone, debug filter, and response scale byte-for-byte equivalent to
// evaluatePackedLocalLight above. The explicit constant-index calls in
// surfaceComputeLocalLightPbr keep the packed array GLES2-safe.
vec3 surfaceEvaluatePackedLocalLightPbr(
    vec4 a, vec4 b, vec4 c, vec4 d, vec4 e, vec4 f,
    vec3 n, vec3 worldPos, vec3 viewDir, vec3 base, vec3 f0,
    float roughness, float metalness)
{
    float lightType = floor(a.w + 0.5);
    if (uLightingDebugLightType > 0.5
        && abs(lightType - uLightingDebugLightType) > 0.5) {
        return vec3(0.0);
    }
    vec3 source = a.xyz;
    vec3 direction = normalize(b.xyz);
    float range = max(b.w, 0.0);
    if (range <= 0.0001 || c.w <= 0.0001 || lightType <= 0.5) {
        return vec3(0.0);
    }

    // SurfaceLight uses the closest point on its emitting face, exactly like
    // the legacy local-light path. SpotLight and SurfaceLight then share the
    // authored face-direction cone test below.
    if (lightType > 2.5) {
        vec3 axisU = d.xyz;
        vec3 axisV = e.xyz;
        vec3 rel = worldPos - source;
        source += axisU * clamp(dot(rel, axisU), -d.w, d.w);
        source += axisV
            * clamp(dot(worldPos - source, axisV), -e.w, e.w);
    }

    vec3 toLight = source - worldPos;
    float dist = length(toLight);
    if (dist >= range || dist <= 0.000001) {
        return vec3(0.0);
    }
    float t = dist / range;
    float rangeAtten = clamp(1.0 - t * t, 0.0, 1.0);
    float coneAtten = 1.0;
    if (lightType > 1.5) {
        vec3 fromLight = normalize(worldPos - source);
        float coneDot = dot(direction, fromLight);
        coneAtten = clamp((coneDot - f.x) * f.y, 0.0, 1.0);
    }

    vec3 lightDir = normalize(toLight);
    float ndotl = max(dot(n, lightDir), 0.0);
    if (ndotl <= 0.0) {
        return vec3(0.0);
    }
    vec3 halfDir = normalize(lightDir + viewDir);
    float ndotv = max(dot(n, viewDir), 0.0001);
    vec3 fresnel = surfaceFresnelSchlick(
        max(dot(halfDir, viewDir), 0.0), f0);
    float distribution = surfaceDistributionGGX(
        n, halfDir, roughness);
    float geometry = surfaceGeometrySmith(
        n, viewDir, lightDir, roughness);
    vec3 specularBrdf = distribution * geometry * fresnel
        / max(4.0 * ndotv * ndotl, 0.0001);
    vec3 energyDiffuse = (vec3(1.0) - fresnel)
        * (1.0 - metalness);
    vec3 radiance = c.rgb
        * (c.w * uLocalLightResponseScale * rangeAtten * coneAtten);
    return (energyDiffuse * base / 3.14159265
        + specularBrdf * max(uSpecularStrength, 0.04))
        * radiance * ndotl;
}

vec3 surfaceComputeLocalLightPbr(
    vec3 n, vec3 worldPos, vec3 viewDir, vec3 base, vec3 f0,
    float roughness, float metalness)
{
    // Per-pack overflow is deliberately directionless. Preserve its authored
    // low-frequency brightness while removing the energy already reflected by
    // the material's Fresnel term; there is no invented L or specular lobe.
    float ndotv = max(dot(n, viewDir), 0.0);
    vec3 overflowFresnel = surfaceFresnelSchlickRoughness(
        ndotv, f0, roughness);
    vec3 overflowDiffuseEnergy = (vec3(1.0) - overflowFresnel)
        * (1.0 - metalness);
    vec3 localLight = base * overflowDiffuseEnergy
        * uLocalLights[0].rgb;
    float localLightCount = uLocalLights[0].w;
    if (localLightCount > 0.5) {
        localLight += surfaceEvaluatePackedLocalLightPbr(
            uLocalLights[1], uLocalLights[2], uLocalLights[3],
            uLocalLights[4], uLocalLights[5], uLocalLights[6],
            n, worldPos, viewDir, base, f0, roughness, metalness);
    }
    if (localLightCount > 1.5) {
        localLight += surfaceEvaluatePackedLocalLightPbr(
            uLocalLights[7], uLocalLights[8], uLocalLights[9],
            uLocalLights[10], uLocalLights[11], uLocalLights[12],
            n, worldPos, viewDir, base, f0, roughness, metalness);
    }
    if (localLightCount > 2.5) {
        localLight += surfaceEvaluatePackedLocalLightPbr(
            uLocalLights[13], uLocalLights[14], uLocalLights[15],
            uLocalLights[16], uLocalLights[17], uLocalLights[18],
            n, worldPos, viewDir, base, f0, roughness, metalness);
    }
    if (localLightCount > 3.5) {
        localLight += surfaceEvaluatePackedLocalLightPbr(
            uLocalLights[19], uLocalLights[20], uLocalLights[21],
            uLocalLights[22], uLocalLights[23], uLocalLights[24],
            n, worldPos, viewDir, base, f0, roughness, metalness);
    }
    return localLight;
}

vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
{
    vec2 uv = texture_coords;
    if (uFlipV > 0.5) {
        uv.y = 1.0 - uv.y;
    }
    if (uFlipU > 0.5) {
        uv.x = 1.0 - uv.x;
    }

    vec3 n = normalize(vNormal);
    float reflectance = clamp(vReflectance, 0.0, 1.0);
    vec4 texel = Texel(tex, uv);
    vec3 detailColor = texel.rgb;
    if (abs(uDetailContrast - 1.0) > 0.0001) {
        detailColor = applyTextureDetailContrast(detailColor);
    }
    detailColor = mix(vec3(1.0), detailColor, clamp(uTextureColorMix, 0.0, 1.0));
    vec3 base;
    float vertexAlpha = uVertexAlphaIsOne ? 1.0 : vColor.a;
    float outAlpha;
    if (uUseSurfaceAppearance > 0.5) {
        base = vColor.rgb;
        outAlpha = clamp(vertexAlpha, 0.0, 1.0);
        if (uSurfaceColorMapActive > 0.5) {
            // MaterialVariant has no separate Color property: BasePart color
            // is its tint input. SurfaceAppearance keeps its authored uniform.
            vec3 surfaceTint = uUseMaterialVariant > 0.5
                ? vColor.rgb : uSurfaceColor;
            vec3 tintedMap = texel.rgb * surfaceTint;
            if (uSurfaceAlphaMode < 0.5) {
                // Overlay: map alpha reveals the underlying MeshPart/vertex
                // color; Surface Color tints only the map term.
                base = mix(vColor.rgb, tintedMap, texel.a);
            } else if (uSurfaceAlphaMode < 1.5) {
                // Transparency: map alpha controls output opacity.
                base = tintedMap;
                outAlpha = clamp(vertexAlpha * texel.a, 0.0, 1.0);
            } else if (uSurfaceAlphaMode < 2.5) {
                // TintMask: alpha controls tint amount, never transparency.
                base = texel.rgb * mix(vec3(1.0), surfaceTint, texel.a);
            } else {
                // Opaque: ignore map alpha completely.
                base = tintedMap;
            }
        }
        base = max(base, vec3(0.0));
        if (uSurfaceCutoutThreshold >= 0.0
            && uSurfaceAlphaMode > 0.5
            && uSurfaceAlphaMode < 1.5
            && uSurfaceColorMapActive > 0.5
            ) {
            if (texel.a < uSurfaceCutoutThreshold) {
                discard;
            }
            // Surviving cutout texels are opaque coverage.  Keeping map alpha
            // here would depth-write a semi-transparent fragment outside the
            // sorted blend pass.
            outAlpha = 1.0;
        }
    } else {
        // Keep the legacy path byte/behavior compatible.
        base = clamp(vColor.rgb * detailColor, 0.0, 1.0);
        float sampledAlpha = texel.a;
        if (uIgnoreTextureAlpha > 0.5) {
            sampledAlpha = 1.0;
        }
        outAlpha = clamp(vertexAlpha * sampledAlpha, 0.0, 1.0);
    }
    if (uUseMeshTextureLayer > 0.5) {
        vec4 meshTexel = Texel(uMeshTextureLayer, vMeshTextureUV);
        base = mix(base, meshTexel.rgb * vMeshTextureTint, meshTexel.a);
        outAlpha = vertexAlpha;
    }
    outAlpha = min(outAlpha,
        1.0 - clamp(uMaterialSurface.w, 0.0, 1.0));
    if (outAlpha <= 0.0) {
        discard;
    }

    if (uUseNormalMap > 0.5) {
        mat3 normalBasis = buildNormalBasis(n, vWorldPos, uv, vTangent, vBitangent);
        n = normalize(normalBasis * sampleCombinedNormal(uv));
    }

    if (uMeshDebugMode > 0.5) {
        if (uMeshDebugMode < 1.5) {
            vec2 tiled = fract(uv * 8.0);
            vec2 cell = floor(uv * 8.0);
            float checker = mod(cell.x + cell.y, 2.0);
            vec3 grid = mix(vec3(0.08, 0.08, 0.08), vec3(0.88, 0.88, 0.88), checker);
            if (tiled.x < 0.045 || tiled.y < 0.045) {
                grid = vec3(0.05, 0.55, 1.0);
            }
            grid = mix(grid, vec3(fract(uv.x), fract(uv.y), 1.0 - checker), 0.35);
            return vec4(grid, outAlpha);
        } else if (uMeshDebugMode < 2.5) {
            return vec4(clamp(n * 0.5 + 0.5, 0.0, 1.0), outAlpha);
        } else if (uMeshDebugMode < 3.5) {
            vec3 tangent = dot(vTangent, vTangent) > 0.000001 ? normalize(vTangent) : vec3(0.0, 0.0, 0.0);
            return vec4(clamp(tangent * 0.5 + 0.5, 0.0, 1.0), outAlpha);
        } else if (uMeshDebugMode < 4.5) {
            vec3 bitangent = dot(vBitangent, vBitangent) > 0.000001 ? normalize(vBitangent) : vec3(0.0, 0.0, 0.0);
            return vec4(clamp(bitangent * 0.5 + 0.5, 0.0, 1.0), outAlpha);
        } else if (uMeshDebugMode > 6.5 && uMeshDebugMode < 7.5) {
            return vec4(clamp(vColor.rgb, 0.0, 1.0), outAlpha);
        } else if (uMeshDebugMode > 7.5 && uMeshDebugMode < 8.5) {
            return vec4(clamp(detailColor, 0.0, 1.0), outAlpha);
        } else if (uMeshDebugMode > 8.5 && uMeshDebugMode < 9.5) {
            return vec4(clamp(vColor.rgb, 0.0, 1.0), outAlpha);
        } else if (uMeshDebugMode > 9.5 && uMeshDebugMode < 10.5) {
            return gl_FrontFacing ? vec4(0.08, 0.90, 0.22, outAlpha) : vec4(1.0, 0.12, 0.12, outAlpha);
        } else if (uMeshDebugMode > 10.5 && uMeshDebugMode < 11.5) {
            return vec4(1.0, 0.0, 0.85, outAlpha);
        } else if (uMeshDebugMode > 11.5 && uMeshDebugMode < 12.5) {
            return vec4(clamp(vColor.rgb, 0.0, 1.0), outAlpha);
        } else if (uMeshDebugMode > 12.5 && uMeshDebugMode < 13.5) {
            vec2 tile = fract(uv);
            vec2 seamDist = min(tile, 1.0 - tile);
            float seam = 1.0 - smoothstep(0.006, 0.030, min(seamDist.x, seamDist.y));
            vec3 seamBase = mix(vec3(fract(uv.x), fract(uv.y), 0.18), vec3(1.0, 0.0, 0.85), seam);
            return vec4(clamp(seamBase, 0.0, 1.0), outAlpha);
        }
    }

    float roughness = clamp(uMaterialSurface.x, 0.03, 1.0);
    float metalness = clamp(uMaterialSurface.y, 0.0, 1.0);
    if (uUseMaterialMaps > 0.5) {
        vec3 rough_sample = Texel(uRoughnessMap, uv).rgb;
        vec3 metal_sample = Texel(uMetalnessMap, uv).rgb;
        float normal_hint = Texel(uNormalMap, uv).a;
        if (uUseSurfaceAppearance > 0.5) {
            // Roblox data maps consume the red channel only.
            roughness = clamp(rough_sample.r, 0.03, 1.0);
            metalness = clamp(metal_sample.r, 0.0, 1.0);
            if (uUseMaterialVariant > 0.5) {
                roughness = mix(
                    clamp(uMaterialSurface.x, 0.03, 1.0), roughness,
                    clamp(uMaterialMapMask.x, 0.0, 1.0));
                metalness = mix(
                    clamp(uMaterialSurface.y, 0.0, 1.0), metalness,
                    clamp(uMaterialMapMask.y, 0.0, 1.0));
            }
        } else {
            // Preserve the legacy material-map reduction exactly.
            float mappedRoughness = clamp(max(max(rough_sample.r, rough_sample.g), rough_sample.b)
                + normal_hint * 0.000001, 0.03, 1.0);
            float mappedMetalness = clamp(max(max(metal_sample.r, metal_sample.g), metal_sample.b), 0.0, 1.0);
            roughness = mix(roughness, mappedRoughness,
                clamp(uMaterialMapMask.x, 0.0, 1.0));
            metalness = mix(metalness, mappedMetalness,
                clamp(uMaterialMapMask.y, 0.0, 1.0));
        }
    }
    vec3 materialEmission = base * max(uMaterialSurface.z, 0.0);

    vec3 lightDir = normalize(uSunDirection);
    float ndotl = max(dot(n, lightDir), 0.0);

    float contactFill = computeContactFill(vContactAO);
    vec3 coolAmbientTerm = computeFrameCoolAmbientTerm(n) * contactFill;
    vec3 environmentTerm = computeFrameEnvironmentTerm(n) * contactFill;
    vec3 ambientTerm = coolAmbientTerm + environmentTerm;
    float directionalShadow = computeDirectionalShadow(vWorldPos, n);
    vec3 diffuseTerm = computeFrameDiffuseTerm(n) * directionalShadow;
    vec3 localTerm = computeLocalLightContribution(n, vWorldPos);

    if (uLightingDebugView > 0.5 && uLightingDebugView < 1.5) {
        return vec4(base, outAlpha);
    }
    if (uLightingDebugView > 1.5 && uLightingDebugView < 2.5) {
        return vec4(applyFrameFogAndExposure(base * (ambientTerm + diffuseTerm), vWorldPos), outAlpha);
    }
    if (uLightingDebugView > 2.5 && uLightingDebugView < 3.5) {
        return vec4(applyFrameFogAndExposure(base * localTerm, vWorldPos), outAlpha);
    }
    if (uLightingDebugView > 3.5 && uLightingDebugView < 4.5) {
        vec2 localMetric = computeLocalLightMetrics(n, vWorldPos);
        return vec4(localLightHeatmap(localMetric.x), outAlpha);
    }
    if (uLightingDebugView > 4.5 && uLightingDebugView < 5.5) {
        vec2 localMetric = computeLocalLightMetrics(n, vWorldPos);
        return vec4(vec3(localMetric.y), outAlpha);
    }
    if (uLightingDebugView > 5.5 && uLightingDebugView < 6.5) {
        return vec4(clamp(base * localTerm, 0.0, 1.0), outAlpha);
    }
    if (uLightingDebugView > 6.5 && uLightingDebugView < 7.5) {
        return vec4(clamp(n * 0.5 + 0.5, 0.0, 1.0), outAlpha);
    }
    if (uLightingDebugView > 7.5 && uLightingDebugView < 8.5) {
        return vec4(vec3(ndotl), outAlpha);
    }
    if (uLightingDebugView > 8.5 && uLightingDebugView < 9.5) {
        return vec4(vec3(computeFrameSkyVisibility(n)), outAlpha);
    }
    if (uLightingDebugView > 9.5 && uLightingDebugView < 10.5) {
        return vec4(vec3(vContactAO), outAlpha);
    }
    if (uLightingDebugView > 10.5 && uLightingDebugView < 11.5) {
        return vec4(applyFrameFogAndExposure(base * coolAmbientTerm, vWorldPos), outAlpha);
    }
    if (uLightingDebugView > 11.5 && uLightingDebugView < 12.5) {
        return vec4(applyFrameFogAndExposure(base * environmentTerm, vWorldPos), outAlpha);
    }
    if (uLightingDebugView > 12.5 && uLightingDebugView < 13.5) {
        return vec4(applyFrameFogAndExposure(base * diffuseTerm, vWorldPos), outAlpha);
    }
    if (uLightingDebugView > 13.5 && uLightingDebugView < 14.5) {
        return vec4(mix(uAtmosphereColor, uSkyColor, 0.35), outAlpha);
    }

    vec3 viewDir = normalize(uCameraPos - vWorldPos);
    vec3 halfDir = normalize(lightDir + viewDir);
    if (uUseSurfaceAppearance > 0.5) {
        float ndotv = max(dot(n, viewDir), 0.0001);
        float ndotlPbr = max(dot(n, lightDir), 0.0);
        vec3 f0 = mix(vec3(0.04), base, metalness);
        vec3 fresnel = surfaceFresnelSchlick(
            max(dot(halfDir, viewDir), 0.0), f0);
        float distribution = surfaceDistributionGGX(
            n, halfDir, roughness);
        float geometry = surfaceGeometrySmith(
            n, viewDir, lightDir, roughness);
        vec3 specularBrdf = distribution * geometry * fresnel
            / max(4.0 * ndotv * ndotlPbr, 0.0001);
        vec3 energyDiffuse = (vec3(1.0) - fresnel)
            * (1.0 - metalness);
        vec3 sunRadiance = uSunColor
            * (uDiffuseStrength * clamp(uDirectionalIntensity, 0.0, 2.5));
        vec3 directPbr = (energyDiffuse * base / 3.14159265
            + specularBrdf * max(uSpecularStrength, 0.04))
            * sunRadiance * ndotlPbr * directionalShadow;

        vec3 environmentFresnel = surfaceFresnelSchlickRoughness(
            ndotv, f0, roughness);
        vec3 environmentDiffuseEnergy =
            (vec3(1.0) - environmentFresnel)
                * (1.0 - metalness);
        vec3 environmentReflection = mix(
            uSkyColor,
            uSunColor,
            uReflectionSunWeight * (1.0 - roughness));
        vec3 environmentSpecular = environmentReflection
            * environmentFresnel
            * uEnvironmentSpecularScale
            * mix(1.0, 0.16, roughness * roughness)
            * contactFill;
        vec3 localPbr = surfaceComputeLocalLightPbr(
            n, vWorldPos, viewDir, base, f0, roughness, metalness);

        // Native order: add emissive to the combined diffuse lighting term,
        // then multiply that term by albedo. Emissive maps use red only.
        float emissiveMask = clamp(Texel(uEmissiveMap, uv).r, 0.0, 1.0);
        vec3 emissiveLighting = emissiveMask
            * max(uSurfaceEmissiveStrength, 0.0)
            * max(uSurfaceEmissiveTint, vec3(0.0));
        vec3 combinedDiffuseLighting =
            environmentDiffuseEnergy * ambientTerm
            + emissiveLighting;
        vec3 pbrLit = base * combinedDiffuseLighting
            + directPbr + localPbr + environmentSpecular;
        vec3 shaded = prepareFrameShadedColor(
            mix(base, pbrLit, clamp(uLightInfluence, 0.0, 1.0)),
            uBrightness);
        shaded += materialEmission;
        if (uLightingDebugView > 14.5 && uLightingDebugView < 15.5) {
            return vec4(previewFrameHdr(shaded, vWorldPos), outAlpha);
        }
        if (uLightingDebugView > 15.5 && uLightingDebugView < 16.5) {
            return vec4(falseColorLuminance(
                applyFrameFogAndExposure(shaded, vWorldPos)), outAlpha);
        }
        if (uLightingDebugView > 16.5 && uLightingDebugView < 17.5) {
            return vec4(falseColorHue(
                applyFrameFogAndExposure(shaded, vWorldPos)), outAlpha);
        }
        return vec4(applyFrameFogAndExposure(shaded, vWorldPos), outAlpha);
    }
    if (uUseTexturedLighting <= 0.5) {
        float shininess = mix(24.0, 128.0, reflectance);
        float spec = pow(max(dot(n, halfDir), 0.0), shininess)
            * uSpecularStrength * (1.0 + reflectance * 2.0)
            * directionalShadow;
        float fresnel = pow(1.0 - max(dot(n, viewDir), 0.0), 2.0) * uRimStrength * (1.0 + reflectance * 1.2);
        vec3 reflect_color = mix(uSkyColor, uSunColor, uReflectionSunWeight) * (reflectance * 0.22 * uEnvironmentSpecularScale);
        vec3 lit = base * (ambientTerm + diffuseTerm + localTerm) + (uSunColor * spec) + (uSkyColor * (fresnel * 0.15)) + reflect_color;
        vec3 shaded = prepareFrameShadedColor(
            mix(base, lit, clamp(uLightInfluence, 0.0, 1.0)),
            uBrightness);
        shaded += materialEmission;
        if (uLightingDebugView > 14.5 && uLightingDebugView < 15.5) {
            return vec4(previewFrameHdr(shaded, vWorldPos), outAlpha);
        }
        if (uLightingDebugView > 15.5 && uLightingDebugView < 16.5) {
            return vec4(falseColorLuminance(applyFrameFogAndExposure(shaded, vWorldPos)), outAlpha);
        }
        if (uLightingDebugView > 16.5 && uLightingDebugView < 17.5) {
            return vec4(falseColorHue(applyFrameFogAndExposure(shaded, vWorldPos)), outAlpha);
        }
        // No floor — see note in textured shader.
        return vec4(applyFrameFogAndExposure(shaded, vWorldPos), outAlpha);
    }

    float shininess = mix(96.0, 10.0, roughness);
    shininess = mix(shininess, 128.0, reflectance);
    float spec = pow(max(dot(n, halfDir), 0.0), shininess)
        * uSpecularStrength * (1.0 + reflectance * 2.0)
        * directionalShadow;
    float spec_weight = 0.22 + (1.0 - roughness) * 0.78;
    spec_weight = mix(spec_weight, 1.0, metalness * 0.65);

    float fresnel = pow(1.0 - max(dot(n, viewDir), 0.0), 2.0) * uRimStrength * (1.0 + reflectance * 1.2);

    vec3 diffuse_base = base * (ambientTerm + localTerm + diffuseTerm * (1.0 - metalness * 0.35));
    vec3 spec_color = mix(uSunColor, base, metalness * 0.7);
    vec3 reflect_color = mix(uSkyColor, uSunColor, uReflectionSunWeight) * (reflectance * 0.22 * uEnvironmentSpecularScale);
    vec3 lit = diffuse_base + (spec_color * (spec * spec_weight)) + (uSkyColor * (fresnel * 0.15)) + reflect_color;
    vec3 shaded = prepareFrameShadedColor(
        mix(base, lit, clamp(uLightInfluence, 0.0, 1.0)),
        uBrightness);
    shaded += materialEmission;
    if (uLightingDebugView > 14.5 && uLightingDebugView < 15.5) {
        return vec4(previewFrameHdr(shaded, vWorldPos), outAlpha);
    }
    if (uLightingDebugView > 15.5 && uLightingDebugView < 16.5) {
        return vec4(falseColorLuminance(applyFrameFogAndExposure(shaded, vWorldPos)), outAlpha);
    }
    if (uLightingDebugView > 16.5 && uLightingDebugView < 17.5) {
        return vec4(falseColorHue(applyFrameFogAndExposure(shaded, vWorldPos)), outAlpha);
    }
    // No floor — see note in textured shader.
    return vec4(applyFrameFogAndExposure(shaded, vWorldPos), outAlpha);
}
#endif
]]

FAST_TEXTURED_SHADER = RBX._rigid_mesh_glsl .. [[
uniform mat4 uViewRotationMatrix;
uniform mat4 uProjectionMatrix;
uniform vec3 uSunDirection;
uniform vec3 uSunColor;
uniform vec3 uSkyColor;
uniform vec3 uGroundColor;
uniform vec3 uCameraPos;
uniform float uAmbient;
uniform float uDiffuseStrength;
uniform float uTextureColorMix;
uniform float uFlipV;
uniform float uFlipU;
uniform float uDepthBias;
]] .. CAMERA_DEPTH_BIAS_GLSL .. [[
uniform float uIgnoreTextureAlpha;
uniform float uLightInfluence;
uniform float uBrightness;
]] .. LIGHTING_FRAME_GLSL .. [[

varying vec4 vColor;
varying vec3 vLight;
varying vec3 vWorldPos;
varying vec3 vShadowNormal;
varying vec3 vDirectionalTerm;

#ifdef VERTEX
attribute vec3 VertexNormal;
attribute float VertexContactAO;
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vec3 worldNormal = normalize(rbxRigidNormal(VertexNormal));
    vec3 worldPos = rbxRigidPoint(vertex_position.xyz);
    vColor = VertexColor;
    float ndotl = max(dot(worldNormal, uSunDirection), 0.0);
    float contactFill = computeContactFill(VertexContactAO);
    vec3 coolAmbientTerm = computeFrameCoolAmbientTerm(worldNormal) * contactFill;
    vec3 environmentTerm = computeFrameEnvironmentTerm(worldNormal) * contactFill;
    vec3 ambientTerm = coolAmbientTerm + environmentTerm;
    vec3 diffuseTerm = computeFrameDiffuseTerm(worldNormal);
    vec3 localTerm = computeLocalLightContribution(worldNormal, worldPos);
    vWorldPos = worldPos;
    vShadowNormal = worldNormal;
    vDirectionalTerm = diffuseTerm;
    vLight = ambientTerm + diffuseTerm + localTerm;
    if (uLightingDebugView > 1.5 && uLightingDebugView < 2.5) {
        vLight = ambientTerm + diffuseTerm;
    } else if (uLightingDebugView > 2.5 && uLightingDebugView < 3.5) {
        vLight = localTerm;
    } else if (uLightingDebugView > 10.5 && uLightingDebugView < 11.5) {
        vLight = coolAmbientTerm;
    } else if (uLightingDebugView > 11.5 && uLightingDebugView < 12.5) {
        vLight = environmentTerm;
    } else if (uLightingDebugView > 12.5 && uLightingDebugView < 13.5) {
        vLight = diffuseTerm;
    }
    vec4 clipPos = uProjectionMatrix * uViewRotationMatrix
        * vec4(worldPos - uCameraPos, 1.0);
    clipPos = applyCameraDepthBias(clipPos, uProjectionMatrix, uDepthBias);
    return clipPos;
}
#endif

#ifdef PIXEL
vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
{
    vec2 uv = texture_coords;
    if (uFlipV > 0.5) {
        uv.y = 1.0 - uv.y;
    }
    if (uFlipU > 0.5) {
        uv.x = 1.0 - uv.x;
    }

    vec4 texel = Texel(tex, uv);
    float sampledAlpha = texel.a;
    if (uIgnoreTextureAlpha > 0.5) {
        sampledAlpha = 1.0;
    }

    vec3 detailColor = mix(vec3(1.0), texel.rgb, clamp(uTextureColorMix, 0.0, 1.0));
    vec3 base = clamp(vColor.rgb * detailColor, 0.0, 1.0);
    float outAlpha = clamp(vColor.a * sampledAlpha, 0.0, 1.0);
    if (outAlpha <= 0.0) {
        discard;
    }
    if (uLightingDebugView > 0.5 && uLightingDebugView < 1.5) {
        return vec4(base, outAlpha);
    }
    if (uLightingDebugView > 13.5 && uLightingDebugView < 14.5) {
        return vec4(mix(uAtmosphereColor, uSkyColor, 0.35), outAlpha);
    }
    float directionalShadow = computeDirectionalShadow(
        vWorldPos, normalize(vShadowNormal));
    vec3 shadowedLight = vLight
        - vDirectionalTerm * (1.0 - directionalShadow);
    vec3 lit = mix(base, base * shadowedLight,
        clamp(uLightInfluence, 0.0, 1.0));
    vec3 shaded = prepareFrameShadedColor(lit, uBrightness);
    if (uLightingDebugView > 14.5 && uLightingDebugView < 15.5) {
        return vec4(previewFrameHdr(shaded, vWorldPos), outAlpha);
    }
    if (uLightingDebugView > 15.5 && uLightingDebugView < 16.5) {
        return vec4(falseColorLuminance(applyFrameFogAndExposure(shaded, vWorldPos)), outAlpha);
    }
    if (uLightingDebugView > 16.5 && uLightingDebugView < 17.5) {
        return vec4(falseColorHue(applyFrameFogAndExposure(shaded, vWorldPos)), outAlpha);
    }
    // No floor — see note in textured shader.
    return vec4(applyFrameFogAndExposure(shaded, vWorldPos), outAlpha);
}
#endif
]]

OPAQUE_FAST_TEXTURED_SHADER = RBX._rigid_mesh_glsl .. [[
uniform bool uVertexAlphaIsOne;
uniform mat4 uViewRotationMatrix;
uniform mat4 uProjectionMatrix;
uniform vec3 uSunDirection;
uniform vec3 uSunColor;
uniform vec3 uSkyColor;
uniform vec3 uGroundColor;
uniform vec3 uCameraPos;
uniform float uAmbient;
uniform float uDiffuseStrength;
uniform float uTextureColorMix;
uniform float uFlipV;
uniform float uFlipU;
uniform float uDepthBias;
]] .. CAMERA_DEPTH_BIAS_GLSL .. [[
uniform float uIgnoreTextureAlpha;
uniform float uLightInfluence;
uniform float uBrightness;
]] .. LIGHTING_FRAME_GLSL .. [[

varying vec4 vColor;
varying vec3 vLight;
varying vec3 vWorldPos;
varying vec3 vShadowNormal;
varying vec3 vDirectionalTerm;

#ifdef VERTEX
attribute vec3 VertexNormal;
attribute float VertexContactAO;
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vec3 worldNormal = normalize(rbxRigidNormal(VertexNormal));
    vec3 worldPos = rbxRigidPoint(vertex_position.xyz);
    vColor = VertexColor;
    float ndotl = max(dot(worldNormal, uSunDirection), 0.0);
    float contactFill = computeContactFill(VertexContactAO);
    vec3 coolAmbientTerm = computeFrameCoolAmbientTerm(worldNormal) * contactFill;
    vec3 environmentTerm = computeFrameEnvironmentTerm(worldNormal) * contactFill;
    vec3 ambientTerm = coolAmbientTerm + environmentTerm;
    vec3 diffuseTerm = computeFrameDiffuseTerm(worldNormal);
    vec3 localTerm = computeLocalLightContribution(worldNormal, worldPos);
    vWorldPos = worldPos;
    vShadowNormal = worldNormal;
    vDirectionalTerm = diffuseTerm;
    vLight = ambientTerm + diffuseTerm + localTerm;
    if (uLightingDebugView > 1.5 && uLightingDebugView < 2.5) {
        vLight = ambientTerm + diffuseTerm;
    } else if (uLightingDebugView > 2.5 && uLightingDebugView < 3.5) {
        vLight = localTerm;
    } else if (uLightingDebugView > 10.5 && uLightingDebugView < 11.5) {
        vLight = coolAmbientTerm;
    } else if (uLightingDebugView > 11.5 && uLightingDebugView < 12.5) {
        vLight = environmentTerm;
    } else if (uLightingDebugView > 12.5 && uLightingDebugView < 13.5) {
        vLight = diffuseTerm;
    }
    vec4 clipPos = uProjectionMatrix * uViewRotationMatrix
        * vec4(worldPos - uCameraPos, 1.0);
    clipPos = applyCameraDepthBias(clipPos, uProjectionMatrix, uDepthBias);
    return clipPos;
}
#endif

#ifdef PIXEL
vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
{
    vec2 uv = texture_coords;
    if (uFlipV > 0.5) {
        uv.y = 1.0 - uv.y;
    }
    if (uFlipU > 0.5) {
        uv.x = 1.0 - uv.x;
    }

    vec4 texel = Texel(tex, uv);
    float vertexAlpha = uVertexAlphaIsOne ? 1.0 : vColor.a;
    float outAlpha = clamp(vertexAlpha
        * (uIgnoreTextureAlpha > 0.5 ? 1.0 : texel.a), 0.0, 1.0);
    if (outAlpha <= 0.0) {
        discard;
    }
    vec3 detailColor = mix(vec3(1.0), texel.rgb, clamp(uTextureColorMix, 0.0, 1.0));
    vec3 base = clamp(vColor.rgb * detailColor, 0.0, 1.0);
    if (uLightingDebugView > 0.5 && uLightingDebugView < 1.5) {
        return vec4(base, outAlpha);
    }
    if (uLightingDebugView > 13.5 && uLightingDebugView < 14.5) {
        return vec4(mix(uAtmosphereColor, uSkyColor, 0.35), outAlpha);
    }
    float directionalShadow = computeDirectionalShadow(
        vWorldPos, normalize(vShadowNormal));
    vec3 shadowedLight = vLight
        - vDirectionalTerm * (1.0 - directionalShadow);
    vec3 lit = mix(base, base * shadowedLight,
        clamp(uLightInfluence, 0.0, 1.0));
    vec3 shaded = prepareFrameShadedColor(lit, uBrightness);
    if (uLightingDebugView > 14.5 && uLightingDebugView < 15.5) {
        return vec4(previewFrameHdr(shaded, vWorldPos), outAlpha);
    }
    if (uLightingDebugView > 15.5 && uLightingDebugView < 16.5) {
        return vec4(falseColorLuminance(applyFrameFogAndExposure(shaded, vWorldPos)), outAlpha);
    }
    if (uLightingDebugView > 16.5 && uLightingDebugView < 17.5) {
        return vec4(falseColorHue(applyFrameFogAndExposure(shaded, vWorldPos)), outAlpha);
    }
    // No floor — see note in textured shader.
    return vec4(applyFrameFogAndExposure(shaded, vWorldPos), outAlpha);
}
#endif
]]

ALPHA_FAST_TEXTURED_SHADER = RBX._rigid_mesh_glsl .. [[
uniform mat4 uViewRotationMatrix;
uniform mat4 uProjectionMatrix;
uniform vec3 uSunDirection;
uniform vec3 uSunColor;
uniform vec3 uSkyColor;
uniform vec3 uGroundColor;
uniform vec3 uCameraPos;
uniform float uAmbient;
uniform float uDiffuseStrength;
uniform float uTextureColorMix;
uniform float uFlipV;
uniform float uFlipU;
uniform float uDepthBias;
]] .. CAMERA_DEPTH_BIAS_GLSL .. [[
uniform float uIgnoreTextureAlpha;
uniform float uLightInfluence;
uniform float uBrightness;
]] .. LIGHTING_FRAME_GLSL .. [[

varying vec4 vColor;
varying vec3 vLight;
varying vec3 vWorldPos;
varying vec3 vShadowNormal;
varying vec3 vDirectionalTerm;

#ifdef VERTEX
attribute vec3 VertexNormal;
attribute float VertexContactAO;
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vec3 worldNormal = normalize(rbxRigidNormal(VertexNormal));
    vec3 worldPos = rbxRigidPoint(vertex_position.xyz);
    vColor = VertexColor;
    float ndotl = max(dot(worldNormal, uSunDirection), 0.0);
    float contactFill = computeContactFill(VertexContactAO);
    vec3 coolAmbientTerm = computeFrameCoolAmbientTerm(worldNormal) * contactFill;
    vec3 environmentTerm = computeFrameEnvironmentTerm(worldNormal) * contactFill;
    vec3 ambientTerm = coolAmbientTerm + environmentTerm;
    vec3 diffuseTerm = computeFrameDiffuseTerm(worldNormal);
    vec3 localTerm = computeLocalLightContribution(worldNormal, worldPos);
    vWorldPos = worldPos;
    vShadowNormal = worldNormal;
    vDirectionalTerm = diffuseTerm;
    vLight = ambientTerm + diffuseTerm + localTerm;
    if (uLightingDebugView > 1.5 && uLightingDebugView < 2.5) {
        vLight = ambientTerm + diffuseTerm;
    } else if (uLightingDebugView > 2.5 && uLightingDebugView < 3.5) {
        vLight = localTerm;
    } else if (uLightingDebugView > 10.5 && uLightingDebugView < 11.5) {
        vLight = coolAmbientTerm;
    } else if (uLightingDebugView > 11.5 && uLightingDebugView < 12.5) {
        vLight = environmentTerm;
    } else if (uLightingDebugView > 12.5 && uLightingDebugView < 13.5) {
        vLight = diffuseTerm;
    }
    vec4 clipPos = uProjectionMatrix * uViewRotationMatrix
        * vec4(worldPos - uCameraPos, 1.0);
    clipPos = applyCameraDepthBias(clipPos, uProjectionMatrix, uDepthBias);
    return clipPos;
}
#endif

#ifdef PIXEL
vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
{
    vec2 uv = texture_coords;
    if (uFlipV > 0.5) {
        uv.y = 1.0 - uv.y;
    }
    if (uFlipU > 0.5) {
        uv.x = 1.0 - uv.x;
    }

    vec4 texel = Texel(tex, uv);
    float sampledAlpha = mix(texel.a, 1.0, clamp(uIgnoreTextureAlpha, 0.0, 1.0));
    vec3 detailColor = mix(vec3(1.0), texel.rgb, clamp(uTextureColorMix, 0.0, 1.0));
    vec3 base = clamp(vColor.rgb * detailColor, 0.0, 1.0);
    float directionalShadow = computeDirectionalShadow(
        vWorldPos, normalize(vShadowNormal));
    vec3 shadowedLight = vLight
        - vDirectionalTerm * (1.0 - directionalShadow);
    vec3 lit = mix(base, base * shadowedLight,
        clamp(uLightInfluence, 0.0, 1.0));
    float outAlpha = clamp(vColor.a * sampledAlpha, 0.0, 1.0);
    if (outAlpha <= 0.0) {
        discard;
    }
    if (uLightingDebugView > 0.5 && uLightingDebugView < 1.5) {
        return vec4(base, outAlpha);
    }
    vec3 shaded = prepareFrameShadedColor(lit, uBrightness);
    if (uLightingDebugView > 13.5 && uLightingDebugView < 14.5) {
        return vec4(mix(uAtmosphereColor, uSkyColor, 0.35), outAlpha);
    }
    if (uLightingDebugView > 14.5 && uLightingDebugView < 15.5) {
        return vec4(previewFrameHdr(shaded, vWorldPos), outAlpha);
    }
    if (uLightingDebugView > 15.5 && uLightingDebugView < 16.5) {
        return vec4(falseColorLuminance(applyFrameFogAndExposure(shaded, vWorldPos)), outAlpha);
    }
    if (uLightingDebugView > 16.5 && uLightingDebugView < 17.5) {
        return vec4(falseColorHue(applyFrameFogAndExposure(shaded, vWorldPos)), outAlpha);
    }
    // No floor — see note in textured shader.
    return vec4(applyFrameFogAndExposure(shaded, vWorldPos), outAlpha);
}
#endif
]]

SURFACE_OVERLAY_FAST_TEXTURED_SHADER = RBX._rigid_mesh_glsl .. [[
uniform mat4 uViewRotationMatrix;
uniform mat4 uProjectionMatrix;
uniform vec3 uSunDirection;
uniform vec3 uSunColor;
uniform vec3 uSkyColor;
uniform vec3 uGroundColor;
uniform vec3 uCameraPos;
uniform float uAmbient;
uniform float uDiffuseStrength;
uniform float uTextureColorMix;
uniform float uDetailContrast;
uniform float uFlipV;
uniform float uFlipU;
uniform float uDepthBias;
]] .. CAMERA_DEPTH_BIAS_GLSL .. [[
uniform float uIgnoreTextureAlpha;
uniform float uLightInfluence;
uniform float uBrightness;
]] .. LIGHTING_FRAME_GLSL .. [[

varying vec4 vColor;
varying vec3 vLight;
varying vec3 vWorldPos;
varying vec3 vShadowNormal;
varying vec3 vDirectionalTerm;

#ifdef VERTEX
attribute vec3 VertexNormal;
attribute float VertexContactAO;
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vec3 worldNormal = normalize(rbxRigidNormal(VertexNormal));
    vec3 worldPos = rbxRigidPoint(vertex_position.xyz);
    vColor = VertexColor;
    float contactFill = computeContactFill(VertexContactAO);
    vec3 coolAmbientTerm = computeFrameCoolAmbientTerm(worldNormal) * contactFill;
    vec3 environmentTerm = computeFrameEnvironmentTerm(worldNormal) * contactFill;
    vec3 ambientTerm = coolAmbientTerm + environmentTerm;
    vec3 diffuseTerm = computeFrameDiffuseTerm(worldNormal);
    vec3 localTerm = computeLocalLightContribution(worldNormal, worldPos);
    vWorldPos = worldPos;
    vShadowNormal = worldNormal;
    vDirectionalTerm = diffuseTerm;
    vLight = ambientTerm + diffuseTerm + localTerm;
    if (uLightingDebugView > 1.5 && uLightingDebugView < 2.5) {
        vLight = ambientTerm + diffuseTerm;
    } else if (uLightingDebugView > 2.5 && uLightingDebugView < 3.5) {
        vLight = localTerm;
    } else if (uLightingDebugView > 10.5 && uLightingDebugView < 11.5) {
        vLight = coolAmbientTerm;
    } else if (uLightingDebugView > 11.5 && uLightingDebugView < 12.5) {
        vLight = environmentTerm;
    } else if (uLightingDebugView > 12.5 && uLightingDebugView < 13.5) {
        vLight = diffuseTerm;
    }
    vec4 clipPos = uProjectionMatrix * uViewRotationMatrix
        * vec4(worldPos - uCameraPos, 1.0);
    clipPos = applyCameraDepthBias(clipPos, uProjectionMatrix, uDepthBias);
    return clipPos;
}
#endif

#ifdef PIXEL
vec3 applySurfaceOverlayContrast(vec3 color)
{
    return clamp((color - 0.5) * max(uDetailContrast, 0.0) + 0.5, 0.0, 1.0);
}

vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
{
    vec2 uv = texture_coords;
    if (uFlipV > 0.5) {
        uv.y = 1.0 - uv.y;
    }
    if (uFlipU > 0.5) {
        uv.x = 1.0 - uv.x;
    }

    vec4 texel = Texel(tex, uv);
    vec3 detailColor = texel.rgb;
    if (abs(uDetailContrast - 1.0) > 0.0001) {
        detailColor = applySurfaceOverlayContrast(detailColor);
    }
    detailColor = mix(vec3(1.0), detailColor, clamp(uTextureColorMix, 0.0, 1.0));
    vec3 base = clamp(vColor.rgb * detailColor, 0.0, 1.0);
    float sampledAlpha = mix(texel.a, 1.0, clamp(uIgnoreTextureAlpha, 0.0, 1.0));
    float outAlpha = clamp(vColor.a * sampledAlpha, 0.0, 1.0);
    if (outAlpha <= 0.0) {
        discard;
    }
    if (uLightingDebugView > 0.5 && uLightingDebugView < 1.5) {
        return vec4(base, outAlpha);
    }
    if (uLightingDebugView > 13.5 && uLightingDebugView < 14.5) {
        return vec4(mix(uAtmosphereColor, uSkyColor, 0.35), outAlpha);
    }
    float directionalShadow = computeDirectionalShadow(
        vWorldPos, normalize(vShadowNormal));
    vec3 shadowedLight = vLight
        - vDirectionalTerm * (1.0 - directionalShadow);
    vec3 lit = mix(base, base * shadowedLight,
        clamp(uLightInfluence, 0.0, 1.0));
    vec3 shaded = prepareFrameShadedColor(lit, uBrightness);
    if (uLightingDebugView > 14.5 && uLightingDebugView < 15.5) {
        return vec4(previewFrameHdr(shaded, vWorldPos), outAlpha);
    }
    if (uLightingDebugView > 15.5 && uLightingDebugView < 16.5) {
        return vec4(falseColorLuminance(applyFrameFogAndExposure(shaded, vWorldPos)), outAlpha);
    }
    if (uLightingDebugView > 16.5 && uLightingDebugView < 17.5) {
        return vec4(falseColorHue(applyFrameFogAndExposure(shaded, vWorldPos)), outAlpha);
    }
    return vec4(applyFrameFogAndExposure(shaded, vWorldPos), outAlpha);
}
#endif
]]

OVERLAY_TEXTURED_SHADER = RBX._rigid_mesh_glsl .. [[
uniform mat4 uViewRotationMatrix;
uniform mat4 uProjectionMatrix;
uniform vec3 uSunDirection;
uniform vec3 uSunColor;
uniform vec3 uSkyColor;
uniform vec3 uGroundColor;
uniform vec3 uCameraPos;
uniform float uAmbient;
uniform float uDiffuseStrength;
uniform float uTextureColorMix;
uniform float uFlipV;
uniform float uFlipU;
uniform float uDepthBias;
]] .. CAMERA_DEPTH_BIAS_GLSL .. [[
uniform float uIgnoreTextureAlpha;
uniform float uTexturePremultiplied;
uniform float uVertexColorPremultiplied;
uniform float uLightInfluence;
uniform float uBrightness;
]] .. LIGHTING_FRAME_GLSL .. [[

varying vec4 vColor;
varying vec3 vLight;
varying vec3 vWorldPos;
varying vec3 vShadowNormal;
varying vec3 vDirectionalTerm;

#ifdef VERTEX
attribute vec3 VertexNormal;
attribute float VertexContactAO;
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vec3 worldNormal = normalize(rbxRigidNormal(VertexNormal));
    vec3 worldPos = rbxRigidPoint(vertex_position.xyz);
    vColor = VertexColor;
    vWorldPos = worldPos;
    vLight = vec3(1.0);
    vShadowNormal = worldNormal;
    vDirectionalTerm = vec3(0.0);
    // SurfaceGui defaults to LightInfluence=0. Uniform branching here avoids
    // thirteen frame terms plus four local-light evaluations for those
    // vertices while still applying fog/exposure in the pixel stage.
    if (uLightInfluence > 0.0001) {
        float contactFill = computeContactFill(VertexContactAO);
        vec3 coolAmbientTerm =
            computeFrameCoolAmbientTerm(worldNormal) * contactFill;
        vec3 environmentTerm =
            computeFrameEnvironmentTerm(worldNormal) * contactFill;
        vec3 ambientTerm = coolAmbientTerm + environmentTerm;
        vec3 diffuseTerm =
            computeFrameDiffuseTerm(worldNormal);
        vec3 localTerm =
            computeLocalLightContribution(worldNormal, worldPos);
        vLight = ambientTerm + diffuseTerm + localTerm;
        vDirectionalTerm = diffuseTerm;
        if (uLightingDebugView > 1.5
            && uLightingDebugView < 2.5) {
            vLight = ambientTerm + diffuseTerm;
        } else if (uLightingDebugView > 2.5
            && uLightingDebugView < 3.5) {
            vLight = localTerm;
        } else if (uLightingDebugView > 10.5
            && uLightingDebugView < 11.5) {
            vLight = coolAmbientTerm;
        } else if (uLightingDebugView > 11.5
            && uLightingDebugView < 12.5) {
            vLight = environmentTerm;
        } else if (uLightingDebugView > 12.5
            && uLightingDebugView < 13.5) {
            vLight = diffuseTerm;
        }
    }
    vec4 clipPos = uProjectionMatrix * uViewRotationMatrix
        * vec4(worldPos - uCameraPos, 1.0);
    clipPos = applyCameraDepthBias(clipPos, uProjectionMatrix, uDepthBias);
    return clipPos;
}
#endif

#ifdef PIXEL
vec4 premultipliedOverlayColor(vec3 rgb, float alpha)
{
    return vec4(rgb * alpha, alpha);
}

vec3 overlayStraightColor(
    vec3 rgb, float alpha, float isPremultiplied)
{
    if (isPremultiplied < 0.5) {
        return rgb;
    }
    return alpha > 0.00001
        ? rgb / alpha
        : vec3(0.0);
}

vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
{
    vec2 uv = texture_coords;
    if (uFlipV > 0.5) {
        uv.y = 1.0 - uv.y;
    }
    if (uFlipU > 0.5) {
        uv.x = 1.0 - uv.x;
    }

    vec4 texel = Texel(tex, uv);
    float sampledAlpha = mix(texel.a, 1.0, clamp(uIgnoreTextureAlpha, 0.0, 1.0));
    float outAlpha = clamp(vColor.a * sampledAlpha, 0.0, 1.0);
    if (outAlpha <= 0.0) {
        discard;
    }
    vec3 textureColor = overlayStraightColor(
        texel.rgb, texel.a, uTexturePremultiplied);
    vec3 vertexColor = overlayStraightColor(
        vColor.rgb, vColor.a, uVertexColorPremultiplied);
    vec3 detailColor = mix(
        vec3(1.0),
        textureColor,
        clamp(uTextureColorMix, 0.0, 1.0));
    vec3 base = clamp(vertexColor * detailColor, 0.0, 1.0);
    if (uLightingDebugView > 0.5 && uLightingDebugView < 1.5) {
        return premultipliedOverlayColor(base, outAlpha);
    }
    if (uLightingDebugView > 13.5 && uLightingDebugView < 14.5) {
        return premultipliedOverlayColor(
            mix(uAtmosphereColor, uSkyColor, 0.35), outAlpha);
    }
    float directionalShadow = computeDirectionalShadow(
        vWorldPos, normalize(vShadowNormal));
    vec3 shadowedLight = vLight
        - vDirectionalTerm * (1.0 - directionalShadow);
    vec3 lit = mix(base, base * shadowedLight,
        clamp(uLightInfluence, 0.0, 1.0));
    vec3 shaded = prepareFrameShadedColor(lit, uBrightness);
    if (uLightingDebugView > 14.5 && uLightingDebugView < 15.5) {
        return premultipliedOverlayColor(
            previewFrameHdr(shaded, vWorldPos), outAlpha);
    }
    if (uLightingDebugView > 15.5 && uLightingDebugView < 16.5) {
        return premultipliedOverlayColor(
            falseColorLuminance(
                applyFrameFogAndExposure(shaded, vWorldPos)),
            outAlpha);
    }
    if (uLightingDebugView > 16.5 && uLightingDebugView < 17.5) {
        return premultipliedOverlayColor(
            falseColorHue(
                applyFrameFogAndExposure(shaded, vWorldPos)),
            outAlpha);
    }
    return premultipliedOverlayColor(
        applyFrameFogAndExposure(shaded, vWorldPos), outAlpha);
}
#endif
]]

-- ArrayImage face layers use the exact overlay-decal receiver path. the only
-- changed operation is the color sampler, this remains a separate lazy program
-- so ordinary overlay packets retain their established compilation and state
FACE_ARRAY_OVERLAY_TEXTURED_SHADER = ([[
#pragma language glsl3
uniform ArrayImage uFaceTextures;
uniform float uFaceLayer;
]] .. OVERLAY_TEXTURED_SHADER):gsub(
    "vec4 texel = Texel%(tex, uv%);",
    "vec4 texel = Texel(uFaceTextures, vec3(uv, uFaceLayer));")

CONSTANT_TEXTURED_SHADER = RBX._rigid_mesh_glsl .. [[
uniform mat4 uViewRotationMatrix;
uniform mat4 uProjectionMatrix;
uniform vec3 uCameraPos;
uniform float uDepthBias;
]] .. CAMERA_DEPTH_BIAS_GLSL .. [[
uniform float uIgnoreTextureAlpha;

varying vec4 vColor;

#ifdef VERTEX
attribute vec3 VertexNormal;
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vec3 worldPos = rbxRigidPoint(vertex_position.xyz);
    vColor = VertexColor;
    vec4 clipPos = uProjectionMatrix * uViewRotationMatrix
        * vec4(worldPos - uCameraPos, 1.0);
    clipPos = applyCameraDepthBias(clipPos, uProjectionMatrix, uDepthBias);
    return clipPos;
}
#endif

#ifdef PIXEL
vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
{
    float alpha = uIgnoreTextureAlpha > 0.5 ? 1.0 : Texel(tex, texture_coords).a;
    float outAlpha = clamp(vColor.a * alpha, 0.0, 1.0);
    if (outAlpha <= 0.0) {
        discard;
    }
    return vec4(0.72, 0.78, 0.68, outAlpha);
}
#endif
]]

INSTANCED_DEPTH_SHADER = [[
uniform mat4 uViewRotationMatrix;
uniform mat4 uProjectionMatrix;
uniform vec3 uCameraPos;
uniform float uDepthBias;
]] .. CAMERA_DEPTH_BIAS_GLSL .. [[

#ifdef VERTEX
attribute vec3 VertexNormal;
attribute vec3 InstancePosition;
attribute vec3 InstanceRight;
attribute vec3 InstanceUp;
attribute vec3 InstanceBack;
attribute vec3 InstanceSize;
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vec3 scaled = vertex_position.xyz * InstanceSize;
    vec3 worldPos = InstancePosition +
        (InstanceRight * scaled.x) +
        (InstanceUp * scaled.y) +
        (InstanceBack * scaled.z);
    vec4 clipPos = uProjectionMatrix * uViewRotationMatrix
        * vec4(worldPos - uCameraPos, 1.0);
    clipPos = applyCameraDepthBias(clipPos, uProjectionMatrix, uDepthBias);
    return clipPos;
}
#endif

#ifdef PIXEL
vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords)
{
    return vec4(1.0);
}
#endif
]]

--[[
instanced MESH shaders: one gpu mesh per geometry signature + per-instance transforms
vertex math must mirror _append_mesh_part_batch's bake:
  world  = InstancePosition + [R U B] * (localPos * InstanceScale)
  normal = normalize([R U B] * (localNormal / InstanceScale))
InstanceScale = the bake's local_scale (axis conversion + mirror signs folded in)
contact AO channel comes off the SIGNED SCALED local normal, not the raw one
depth bias uses the same projected view-depth displacement as every color/depth shader
PIXEL block mirrors OPAQUE_FAST_TEXTURED_SHADER -- keep the frame-shading contract in sync
]]
-- kept behind a compile-time define so ordinary instanced groups retain their
-- existing program and uniform traffic. shared-pose groups rotate each
-- instance's already scaled world-space offset about its own center and add a
-- common translation, their per-instance rows remain an immutable base pose
INSTANCED_MESH_SHARED_POSE_GLSL = [[
#ifdef RBX_SHARED_INSTANCE_POSE
uniform vec3 uSharedPoseTranslation;
uniform vec3 uSharedPoseRow0;
uniform vec3 uSharedPoseRow1;
uniform vec3 uSharedPoseRow2;
vec3 rbxSharedInstancePoseRotate(vec3 value)
{
    return vec3(dot(uSharedPoseRow0, value), dot(uSharedPoseRow1, value),
        dot(uSharedPoseRow2, value));
}
#endif
]]

INSTANCED_MESH_FAST_SHADER = [[
uniform bool uVertexAlphaIsOne;
uniform mat4 uViewRotationMatrix;
uniform mat4 uProjectionMatrix;
uniform vec3 uSunDirection;
uniform vec3 uSunColor;
uniform vec3 uSkyColor;
uniform vec3 uGroundColor;
uniform vec3 uCameraPos;
uniform float uAmbient;
uniform float uDiffuseStrength;
uniform float uTextureColorMix;
uniform float uFlipV;
uniform float uFlipU;
uniform float uDepthBias;
]] .. CAMERA_DEPTH_BIAS_GLSL .. [[
uniform float uIgnoreTextureAlpha;
uniform float uLightInfluence;
uniform float uBrightness;
]] .. INSTANCED_MESH_SHARED_POSE_GLSL .. LIGHTING_FRAME_GLSL .. [[

varying vec4 vColor;
varying vec3 vLight;
varying vec3 vWorldPos;
varying vec3 vShadowNormal;
varying vec3 vDirectionalTerm;

#ifdef VERTEX
attribute vec3 VertexNormal;
attribute vec3 InstancePosition;
attribute vec3 InstanceRight;
attribute vec3 InstanceUp;
attribute vec3 InstanceBack;
attribute vec3 InstanceScale;
attribute vec4 InstanceColor;
attribute vec4 InstanceMisc;
attribute vec4 InstanceContactAO;
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vec3 safeScale = vec3(
        abs(InstanceScale.x) > 1e-6 ? InstanceScale.x : 1e-6,
        abs(InstanceScale.y) > 1e-6 ? InstanceScale.y : 1e-6,
        abs(InstanceScale.z) > 1e-6 ? InstanceScale.z : 1e-6);
    vec3 scaled = vertex_position.xyz * InstanceScale;
    vec3 worldOffset =
        (InstanceRight * scaled.x) +
        (InstanceUp * scaled.y) +
        (InstanceBack * scaled.z);
    vec3 scaledNormal = VertexNormal / safeScale;
    vec3 worldNormal = normalize(
        (InstanceRight * scaledNormal.x) +
        (InstanceUp * scaledNormal.y) +
        (InstanceBack * scaledNormal.z));
#ifdef RBX_SHARED_INSTANCE_POSE
    worldOffset = rbxSharedInstancePoseRotate(worldOffset);
    worldNormal = normalize(rbxSharedInstancePoseRotate(worldNormal));
#endif
    vec3 worldPos = InstancePosition + worldOffset;
#ifdef RBX_SHARED_INSTANCE_POSE
    worldPos += uSharedPoseTranslation;
#endif
    vColor = VertexColor * InstanceColor;
    float contactAO = selectContactAO(scaledNormal, InstanceContactAO);
    float ndotl = max(dot(worldNormal, uSunDirection), 0.0);
    float contactFill = computeContactFill(contactAO);
    vec3 coolAmbientTerm = computeFrameCoolAmbientTerm(worldNormal) * contactFill;
    vec3 environmentTerm = computeFrameEnvironmentTerm(worldNormal) * contactFill;
    vec3 ambientTerm = coolAmbientTerm + environmentTerm;
    vec3 diffuseTerm = computeFrameDiffuseTerm(worldNormal);
    vec3 localTerm = computeLocalLightContribution(worldNormal, worldPos);
    vWorldPos = worldPos;
    vShadowNormal = worldNormal;
    vDirectionalTerm = diffuseTerm;
    vLight = ambientTerm + diffuseTerm + localTerm;
    if (uLightingDebugView > 1.5 && uLightingDebugView < 2.5) {
        vLight = ambientTerm + diffuseTerm;
    } else if (uLightingDebugView > 2.5 && uLightingDebugView < 3.5) {
        vLight = localTerm;
    } else if (uLightingDebugView > 10.5 && uLightingDebugView < 11.5) {
        vLight = coolAmbientTerm;
    } else if (uLightingDebugView > 11.5 && uLightingDebugView < 12.5) {
        vLight = environmentTerm;
    } else if (uLightingDebugView > 12.5 && uLightingDebugView < 13.5) {
        vLight = diffuseTerm;
    }
    vec4 clipPos = uProjectionMatrix * uViewRotationMatrix
        * vec4(worldPos - uCameraPos, 1.0);
    clipPos = applyCameraDepthBias(clipPos, uProjectionMatrix, uDepthBias);
    return clipPos;
}
#endif

#ifdef PIXEL
vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
{
    vec2 uv = texture_coords;
    if (uFlipV > 0.5) {
        uv.y = 1.0 - uv.y;
    }
    if (uFlipU > 0.5) {
        uv.x = 1.0 - uv.x;
    }

    vec4 texel = Texel(tex, uv);
    float vertexAlpha = uVertexAlphaIsOne ? 1.0 : vColor.a;
    float outAlpha = clamp(vertexAlpha
        * (uIgnoreTextureAlpha > 0.5 ? 1.0 : texel.a), 0.0, 1.0);
    if (outAlpha <= 0.0) {
        discard;
    }
    vec3 detailColor = mix(vec3(1.0), texel.rgb, clamp(uTextureColorMix, 0.0, 1.0));
    vec3 base = clamp(vColor.rgb * detailColor, 0.0, 1.0);
    if (uLightingDebugView > 0.5 && uLightingDebugView < 1.5) {
        return vec4(base, outAlpha);
    }
    if (uLightingDebugView > 13.5 && uLightingDebugView < 14.5) {
        return vec4(mix(uAtmosphereColor, uSkyColor, 0.35), outAlpha);
    }
    float directionalShadow = computeDirectionalShadow(
        vWorldPos, normalize(vShadowNormal));
    vec3 shadowedLight = vLight
        - vDirectionalTerm * (1.0 - directionalShadow);
    vec3 lit = mix(base, base * shadowedLight,
        clamp(uLightInfluence, 0.0, 1.0));
    vec3 shaded = prepareFrameShadedColor(lit, uBrightness);
    if (uLightingDebugView > 14.5 && uLightingDebugView < 15.5) {
        return vec4(previewFrameHdr(shaded, vWorldPos), outAlpha);
    }
    if (uLightingDebugView > 15.5 && uLightingDebugView < 16.5) {
        return vec4(falseColorLuminance(applyFrameFogAndExposure(shaded, vWorldPos)), outAlpha);
    }
    if (uLightingDebugView > 16.5 && uLightingDebugView < 17.5) {
        return vec4(falseColorHue(applyFrameFogAndExposure(shaded, vWorldPos)), outAlpha);
    }
    // No floor — see note in textured shader.
    return vec4(applyFrameFogAndExposure(shaded, vWorldPos), outAlpha);
}
#endif
]]

--[[ depth-prepass variant for instanced meshes. prepass is off by default but must still
work if a caller enables it. same world transform as the color variants ]]
INSTANCED_MESH_DEPTH_SHADER = [[
uniform mat4 uViewRotationMatrix;
uniform mat4 uProjectionMatrix;
uniform vec3 uCameraPos;
uniform float uDepthBias;
]] .. CAMERA_DEPTH_BIAS_GLSL .. [[
uniform float uIgnoreTextureAlpha;
uniform float uFlipU;
uniform float uFlipV;
]] .. INSTANCED_MESH_SHARED_POSE_GLSL .. [[
varying float vDepthAlpha;

#ifdef VERTEX
attribute vec3 InstancePosition;
attribute vec3 InstanceRight;
attribute vec3 InstanceUp;
attribute vec3 InstanceBack;
attribute vec3 InstanceScale;
attribute vec4 InstanceColor;
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vec3 scaled = vertex_position.xyz * InstanceScale;
    vec3 worldOffset =
        (InstanceRight * scaled.x) +
        (InstanceUp * scaled.y) +
        (InstanceBack * scaled.z);
#ifdef RBX_SHARED_INSTANCE_POSE
    worldOffset = rbxSharedInstancePoseRotate(worldOffset);
#endif
    vec3 worldPos = InstancePosition + worldOffset;
#ifdef RBX_SHARED_INSTANCE_POSE
    worldPos += uSharedPoseTranslation;
#endif
    vDepthAlpha = VertexColor.a * InstanceColor.a;
    vec4 clipPos = uProjectionMatrix * uViewRotationMatrix
        * vec4(worldPos - uCameraPos, 1.0);
    clipPos = applyCameraDepthBias(clipPos, uProjectionMatrix, uDepthBias);
    return clipPos;
}
#endif

#ifdef PIXEL
vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords)
{
    vec2 uv = texture_coords;
    if (uFlipU > 0.5) uv.x = 1.0 - uv.x;
    if (uFlipV > 0.5) uv.y = 1.0 - uv.y;
    float textureAlpha = uIgnoreTextureAlpha > 0.5
        ? 1.0 : Texel(texture, uv).a;
    if (vDepthAlpha * textureAlpha <= 0.003) {
        discard;
    }
    return vec4(1.0);
}
#endif
]]

--[[
instanced shader for MATERIAL-PROJECTED parts: redoes the projected-uv bake in the vertex
stage. projection input is the SIGNED-SCALED LOCAL position, NEVER world:
  uv = ((dot(faceAxis, localPos*effScale) - minRange) / studsPerTile) * tiling
effScale folds the extra-mirror signs into the scale. the per-triangle face choice is baked
per-vertex (VertexFaceId, csg normal-id order 0=Right 1=Top 2=Back 3=Left 4=Bottom 5=Front),
so the shader does no face-mirror logic. minRange = min(dot(axis, lo), dot(axis, hi)) over
the effective-scaled bounds. tangent varyings are zero (only tangent-less meshes are
eligible). PIXEL block is verbatim TEXTURED_SHADER -- keep in sync
]]
INSTANCED_MESH_MATERIAL_SHADER = [[
uniform mat4 uViewRotationMatrix;
uniform mat4 uProjectionMatrix;
uniform vec3 uSunDirection;
uniform vec3 uSunColor;
uniform vec3 uSkyColor;
uniform vec3 uGroundColor;
uniform vec3 uCameraPos;
uniform float uAmbient;
uniform float uDiffuseStrength;
uniform float uSpecularStrength;
uniform float uRimStrength;
uniform float uUseMaterialMaps;
uniform float uUseTexturedLighting;
uniform float uUseNormalMap;
uniform float uDetailNormalMix;
uniform float uDetailContrast;
uniform float uTextureColorMix;
uniform float uFlipV;
uniform float uFlipU;
uniform float uDepthBias;
]] .. CAMERA_DEPTH_BIAS_GLSL .. [[
uniform float uIgnoreTextureAlpha;
uniform bool uVertexAlphaIsOne;
uniform float uLightInfluence;
uniform float uBrightness;
uniform float uMeshDebugMode;
uniform float uStudsPerTile;
uniform float uMaterialTiling;
uniform float uPrimitiveMaterial;
uniform vec3 uProjBoundsMin;
uniform vec3 uProjBoundsMax;
uniform vec3 uProjEmSign;
uniform vec3 uProjBoundsSign;
// Same descriptor ABI as TEXTURED_SHADER. Projected repeated meshes are
// bucketed by material, so these remain one uniform update per group rather
// than growing the instance row.
uniform vec4 uMaterialSurface;
uniform vec2 uMaterialMapMask;
]] .. LIGHTING_FRAME_GLSL .. [[
extern Image uNormalMap;
extern Image uDetailNormalMap;
extern Image uRoughnessMap;
extern Image uMetalnessMap;

varying vec3 vNormal;
varying vec4 vColor;
varying vec3 vWorldPos;
varying float vReflectance;
varying vec3 vTangent;
varying vec3 vBitangent;
varying float vContactAO;

#ifdef VERTEX
attribute vec3 VertexNormal;
attribute float VertexFaceId;
attribute vec3 InstancePosition;
attribute vec3 InstanceRight;
attribute vec3 InstanceUp;
attribute vec3 InstanceBack;
attribute vec3 InstanceScale;
attribute vec4 InstanceColor;
attribute vec4 InstanceMisc;
attribute vec4 InstanceContactAO;
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vec3 safeScale = vec3(
        abs(InstanceScale.x) > 1e-6 ? InstanceScale.x : 1e-6,
        abs(InstanceScale.y) > 1e-6 ? InstanceScale.y : 1e-6,
        abs(InstanceScale.z) > 1e-6 ? InstanceScale.z : 1e-6);
    vec3 scaled = vertex_position.xyz * InstanceScale;
    vec3 worldPos = InstancePosition +
        (InstanceRight * scaled.x) +
        (InstanceUp * scaled.y) +
        (InstanceBack * scaled.z);
    vec3 scaledNormal = VertexNormal / safeScale;
    vec3 worldNormal = normalize(
        (InstanceRight * scaledNormal.x) +
        (InstanceUp * scaledNormal.y) +
        (InstanceBack * scaledNormal.z));

    vec3 uvLocal = vertex_position.xyz * (InstanceScale * uProjEmSign);
    vec3 boundsScale = InstanceScale * uProjBoundsSign;
    vec3 boundsA = uProjBoundsMin * boundsScale;
    vec3 boundsB = uProjBoundsMax * boundsScale;
    vec3 boundsLo = min(boundsA, boundsB);
    vec3 boundsHi = max(boundsA, boundsB);
    vec3 axisU;
    vec3 axisV;
    if (VertexFaceId < 0.5) {          // Right
        axisU = vec3(0.0, 0.0, -1.0); axisV = vec3(0.0, 1.0, 0.0);
    } else if (VertexFaceId < 1.5) {   // Top
        axisU = vec3(1.0, 0.0, 0.0);  axisV = vec3(0.0, 0.0, 1.0);
    } else if (VertexFaceId < 2.5) {   // Back
        axisU = vec3(1.0, 0.0, 0.0);  axisV = vec3(0.0, 1.0, 0.0);
    } else if (VertexFaceId < 3.5) {   // Left
        axisU = vec3(0.0, 0.0, 1.0);  axisV = vec3(0.0, 1.0, 0.0);
    } else if (VertexFaceId < 4.5) {   // Bottom
        axisU = vec3(1.0, 0.0, 0.0);  axisV = vec3(0.0, 0.0, -1.0);
    } else {                           // Front
        axisU = vec3(-1.0, 0.0, 0.0); axisV = vec3(0.0, 1.0, 0.0);
    }
    float minU = min(dot(axisU, boundsLo), dot(axisU, boundsHi));
    float minV = min(dot(axisV, boundsLo), dot(axisV, boundsHi));
    float projU = ((dot(axisU, uvLocal) - minU) / uStudsPerTile) * uMaterialTiling;
    float projV = ((dot(axisV, uvLocal) - minV) / uStudsPerTile) * uMaterialTiling;
    VaryingTexCoord = vec4(projU, projV, 0.0, 1.0);

    vNormal = worldNormal;
    vWorldPos = worldPos;
    vColor = VertexColor * InstanceColor;
    vReflectance = clamp(InstanceMisc.x, 0.0, 1.0);
    vTangent = vec3(0.0);
    vBitangent = vec3(0.0);
    // Primitive contact channels describe authored faces, as in the regular
    // primitive-instancing shader. Imported meshes retain their established
    // scaled-normal selection without changing the shared instance ABI.
    vec3 contactNormal = uPrimitiveMaterial > 0.5 ? VertexNormal : scaledNormal;
    vContactAO = clamp(selectContactAO(contactNormal, InstanceContactAO), 0.0, 1.0);
    vec4 clipPos = uProjectionMatrix * uViewRotationMatrix
        * vec4(worldPos - uCameraPos, 1.0);
    clipPos = applyCameraDepthBias(clipPos, uProjectionMatrix, uDepthBias);
    return clipPos;
}
#endif

#ifdef PIXEL
vec3 decodeNormal(vec4 sampleColor)
{
    vec3 normal = sampleColor.rgb * 2.0 - 1.0;
    return normalize(vec3(normal.xy, max(normal.z, 0.0001)));
}

vec3 getNormalWithStrength(vec3 normal, float multiplier)
{
    float theta = atan(normal.x, normal.y);
    float phi = acos(clamp(normal.z, -1.0, 1.0)) * max(multiplier, 0.0);
    float phiSin = sin(phi);
    return normalize(vec3(
        sin(theta) * phiSin,
        cos(theta) * phiSin,
        cos(phi)
    ));
}

vec3 combineDetailNormals(vec3 primary, vec3 secondary, float multiplier)
{
    vec3 base = normalize(primary);
    vec3 detail = getNormalWithStrength(normalize(secondary), multiplier);

    base += vec3(0.0, 0.0, 1.0);
    detail *= vec3(-1.0, -1.0, 1.0);

    return normalize((base / max(base.z, 0.0001)) * dot(base, detail) - detail);
}

mat3 buildNormalBasis(vec3 worldNormal, vec3 worldPos, vec2 uv, vec3 tangentHint, vec3 bitangentHint)
{
    float tangentHintLenSq = dot(tangentHint, tangentHint);
    float bitangentHintLenSq = dot(bitangentHint, bitangentHint);
    if (tangentHintLenSq > 0.000001 && bitangentHintLenSq > 0.000001) {
        if (uFlipU > 0.5) {
            tangentHint *= -1.0;
        }
        if (uFlipV > 0.5) {
            bitangentHint *= -1.0;
        }
        vec3 tangent = tangentHint - worldNormal * dot(worldNormal, tangentHint);
        float tangentLenSq = dot(tangent, tangent);
        if (tangentLenSq > 0.000001) {
            tangent *= inversesqrt(tangentLenSq);
            vec3 bitangent = bitangentHint
                - worldNormal * dot(worldNormal, bitangentHint)
                - tangent * dot(tangent, bitangentHint);
            float bitangentLenSq = dot(bitangent, bitangent);
            if (bitangentLenSq > 0.000001) {
                bitangent *= inversesqrt(bitangentLenSq);
                if (dot(cross(tangent, bitangent), worldNormal) < 0.0) {
                    bitangent *= -1.0;
                }
                return mat3(tangent, bitangent, worldNormal);
            }
        }
    }

    vec3 dp1 = dFdx(worldPos);
    vec3 dp2 = dFdy(worldPos);
    vec2 duv1 = dFdx(uv);
    vec2 duv2 = dFdy(uv);

    vec3 dp2perp = cross(dp2, worldNormal);
    vec3 dp1perp = cross(worldNormal, dp1);
    vec3 tangent = dp2perp * duv1.x + dp1perp * duv2.x;
    vec3 bitangent = dp2perp * duv1.y + dp1perp * duv2.y;

    float tangentLenSq = dot(tangent, tangent);
    float bitangentLenSq = dot(bitangent, bitangent);
    if (tangentLenSq <= 0.000001 || bitangentLenSq <= 0.000001) {
        vec3 axis = abs(worldNormal.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
        tangent = normalize(cross(axis, worldNormal));
        bitangent = normalize(cross(worldNormal, tangent));
        return mat3(tangent, bitangent, worldNormal);
    }

    float invMax = inversesqrt(max(tangentLenSq, bitangentLenSq));
    tangent *= invMax;
    bitangent *= invMax;
    return mat3(tangent, bitangent, worldNormal);
}

vec3 sampleCombinedNormal(vec2 uv)
{
    vec3 primary = decodeNormal(Texel(uNormalMap, uv));
    if (uDetailNormalMix <= 0.0001) {
        return primary;
    }

    vec3 detail = decodeNormal(Texel(uDetailNormalMap, uv));
    return combineDetailNormals(primary, detail, uDetailNormalMix);
}

vec3 applyTextureDetailContrast(vec3 color)
{
    return clamp((color - 0.5) * max(uDetailContrast, 0.0) + 0.5, 0.0, 1.0);
}

vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
{
    vec2 uv = texture_coords;
    if (uFlipV > 0.5) {
        uv.y = 1.0 - uv.y;
    }
    if (uFlipU > 0.5) {
        uv.x = 1.0 - uv.x;
    }

    vec3 n = normalize(vNormal);
    float reflectance = clamp(vReflectance, 0.0, 1.0);
    vec4 texel = Texel(tex, uv);
    vec3 detailColor = texel.rgb;
    if (abs(uDetailContrast - 1.0) > 0.0001) {
        detailColor = applyTextureDetailContrast(detailColor);
    }
    detailColor = mix(vec3(1.0), detailColor, clamp(uTextureColorMix, 0.0, 1.0));
    vec3 base = clamp(vColor.rgb * detailColor, 0.0, 1.0);
    float sampledAlpha = texel.a;
    if (uIgnoreTextureAlpha > 0.5) {
        sampledAlpha = 1.0;
    }
    float vertexAlpha = uVertexAlphaIsOne ? 1.0 : vColor.a;
    float outAlpha = clamp(vertexAlpha * sampledAlpha, 0.0, 1.0);
    if (outAlpha <= 0.0) {
        discard;
    }

    if (uUseNormalMap > 0.5) {
        mat3 normalBasis = buildNormalBasis(n, vWorldPos, uv, vTangent, vBitangent);
        n = normalize(normalBasis * sampleCombinedNormal(uv));
    }

    if (uMeshDebugMode > 0.5) {
        if (uMeshDebugMode < 1.5) {
            vec2 tiled = fract(uv * 8.0);
            vec2 cell = floor(uv * 8.0);
            float checker = mod(cell.x + cell.y, 2.0);
            vec3 grid = mix(vec3(0.08, 0.08, 0.08), vec3(0.88, 0.88, 0.88), checker);
            if (tiled.x < 0.045 || tiled.y < 0.045) {
                grid = vec3(0.05, 0.55, 1.0);
            }
            grid = mix(grid, vec3(fract(uv.x), fract(uv.y), 1.0 - checker), 0.35);
            return vec4(grid, outAlpha);
        } else if (uMeshDebugMode < 2.5) {
            return vec4(clamp(n * 0.5 + 0.5, 0.0, 1.0), outAlpha);
        } else if (uMeshDebugMode < 3.5) {
            vec3 tangent = dot(vTangent, vTangent) > 0.000001 ? normalize(vTangent) : vec3(0.0, 0.0, 0.0);
            return vec4(clamp(tangent * 0.5 + 0.5, 0.0, 1.0), outAlpha);
        } else if (uMeshDebugMode < 4.5) {
            vec3 bitangent = dot(vBitangent, vBitangent) > 0.000001 ? normalize(vBitangent) : vec3(0.0, 0.0, 0.0);
            return vec4(clamp(bitangent * 0.5 + 0.5, 0.0, 1.0), outAlpha);
        } else if (uMeshDebugMode > 6.5 && uMeshDebugMode < 7.5) {
            return vec4(clamp(vColor.rgb, 0.0, 1.0), outAlpha);
        } else if (uMeshDebugMode > 7.5 && uMeshDebugMode < 8.5) {
            return vec4(clamp(detailColor, 0.0, 1.0), outAlpha);
        } else if (uMeshDebugMode > 8.5 && uMeshDebugMode < 9.5) {
            return vec4(clamp(vColor.rgb, 0.0, 1.0), outAlpha);
        } else if (uMeshDebugMode > 9.5 && uMeshDebugMode < 10.5) {
            return gl_FrontFacing ? vec4(0.08, 0.90, 0.22, outAlpha) : vec4(1.0, 0.12, 0.12, outAlpha);
        } else if (uMeshDebugMode > 10.5 && uMeshDebugMode < 11.5) {
            return vec4(1.0, 0.0, 0.85, outAlpha);
        } else if (uMeshDebugMode > 11.5 && uMeshDebugMode < 12.5) {
            return vec4(clamp(vColor.rgb, 0.0, 1.0), outAlpha);
        } else if (uMeshDebugMode > 12.5 && uMeshDebugMode < 13.5) {
            vec2 tile = fract(uv);
            vec2 seamDist = min(tile, 1.0 - tile);
            float seam = 1.0 - smoothstep(0.006, 0.030, min(seamDist.x, seamDist.y));
            vec3 seamBase = mix(vec3(fract(uv.x), fract(uv.y), 0.18), vec3(1.0, 0.0, 0.85), seam);
            return vec4(clamp(seamBase, 0.0, 1.0), outAlpha);
        }
    }

    float roughness = clamp(uMaterialSurface.x, 0.03, 1.0);
    float metalness = clamp(uMaterialSurface.y, 0.0, 1.0);
    if (uUseMaterialMaps > 0.5) {
        vec3 rough_sample = Texel(uRoughnessMap, uv).rgb;
        vec3 metal_sample = Texel(uMetalnessMap, uv).rgb;
        float normal_hint = Texel(uNormalMap, uv).a;

        float mappedRoughness = clamp(max(max(rough_sample.r, rough_sample.g), rough_sample.b) + normal_hint * 0.000001, 0.03, 1.0);
        float mappedMetalness = clamp(max(max(metal_sample.r, metal_sample.g), metal_sample.b), 0.0, 1.0);
        roughness = mix(roughness, mappedRoughness,
            clamp(uMaterialMapMask.x, 0.0, 1.0));
        metalness = mix(metalness, mappedMetalness,
            clamp(uMaterialMapMask.y, 0.0, 1.0));
    }
    vec3 materialEmission = base * max(uMaterialSurface.z, 0.0);

    vec3 lightDir = normalize(uSunDirection);
    float ndotl = max(dot(n, lightDir), 0.0);

    float contactFill = computeContactFill(vContactAO);
    vec3 coolAmbientTerm = computeFrameCoolAmbientTerm(n) * contactFill;
    vec3 environmentTerm = computeFrameEnvironmentTerm(n) * contactFill;
    vec3 ambientTerm = coolAmbientTerm + environmentTerm;
    float directionalShadow = computeDirectionalShadow(vWorldPos, n);
    vec3 diffuseTerm = computeFrameDiffuseTerm(n) * directionalShadow;
    vec3 localTerm = computeLocalLightContribution(n, vWorldPos);

    if (uLightingDebugView > 0.5 && uLightingDebugView < 1.5) {
        return vec4(base, outAlpha);
    }
    if (uLightingDebugView > 1.5 && uLightingDebugView < 2.5) {
        return vec4(applyFrameFogAndExposure(base * (ambientTerm + diffuseTerm), vWorldPos), outAlpha);
    }
    if (uLightingDebugView > 2.5 && uLightingDebugView < 3.5) {
        return vec4(applyFrameFogAndExposure(base * localTerm, vWorldPos), outAlpha);
    }
    if (uLightingDebugView > 3.5 && uLightingDebugView < 4.5) {
        vec2 localMetric = computeLocalLightMetrics(n, vWorldPos);
        return vec4(localLightHeatmap(localMetric.x), outAlpha);
    }
    if (uLightingDebugView > 4.5 && uLightingDebugView < 5.5) {
        vec2 localMetric = computeLocalLightMetrics(n, vWorldPos);
        return vec4(vec3(localMetric.y), outAlpha);
    }
    if (uLightingDebugView > 5.5 && uLightingDebugView < 6.5) {
        return vec4(clamp(base * localTerm, 0.0, 1.0), outAlpha);
    }
    if (uLightingDebugView > 6.5 && uLightingDebugView < 7.5) {
        return vec4(clamp(n * 0.5 + 0.5, 0.0, 1.0), outAlpha);
    }
    if (uLightingDebugView > 7.5 && uLightingDebugView < 8.5) {
        return vec4(vec3(ndotl), outAlpha);
    }
    if (uLightingDebugView > 8.5 && uLightingDebugView < 9.5) {
        return vec4(vec3(computeFrameSkyVisibility(n)), outAlpha);
    }
    if (uLightingDebugView > 9.5 && uLightingDebugView < 10.5) {
        return vec4(vec3(vContactAO), outAlpha);
    }
    if (uLightingDebugView > 10.5 && uLightingDebugView < 11.5) {
        return vec4(applyFrameFogAndExposure(base * coolAmbientTerm, vWorldPos), outAlpha);
    }
    if (uLightingDebugView > 11.5 && uLightingDebugView < 12.5) {
        return vec4(applyFrameFogAndExposure(base * environmentTerm, vWorldPos), outAlpha);
    }
    if (uLightingDebugView > 12.5 && uLightingDebugView < 13.5) {
        return vec4(applyFrameFogAndExposure(base * diffuseTerm, vWorldPos), outAlpha);
    }
    if (uLightingDebugView > 13.5 && uLightingDebugView < 14.5) {
        return vec4(mix(uAtmosphereColor, uSkyColor, 0.35), outAlpha);
    }

    vec3 viewDir = normalize(uCameraPos - vWorldPos);
    vec3 halfDir = normalize(lightDir + viewDir);
    if (uUseTexturedLighting <= 0.5) {
        float shininess = mix(24.0, 128.0, reflectance);
        float spec = pow(max(dot(n, halfDir), 0.0), shininess)
            * uSpecularStrength * (1.0 + reflectance * 2.0)
            * directionalShadow;
        float fresnel = pow(1.0 - max(dot(n, viewDir), 0.0), 2.0) * uRimStrength * (1.0 + reflectance * 1.2);
        vec3 reflect_color = mix(uSkyColor, uSunColor, uReflectionSunWeight) * (reflectance * 0.22 * uEnvironmentSpecularScale);
        vec3 lit = base * (ambientTerm + diffuseTerm + localTerm) + (uSunColor * spec) + (uSkyColor * (fresnel * 0.15)) + reflect_color;
        vec3 shaded = prepareFrameShadedColor(
            mix(base, lit, clamp(uLightInfluence, 0.0, 1.0)),
            uBrightness);
        if (uLightingDebugView > 14.5 && uLightingDebugView < 15.5) {
            return vec4(previewFrameHdr(shaded, vWorldPos), outAlpha);
        }
        if (uLightingDebugView > 15.5 && uLightingDebugView < 16.5) {
            return vec4(falseColorLuminance(applyFrameFogAndExposure(shaded, vWorldPos)), outAlpha);
        }
        if (uLightingDebugView > 16.5 && uLightingDebugView < 17.5) {
            return vec4(falseColorHue(applyFrameFogAndExposure(shaded, vWorldPos)), outAlpha);
        }
        // No floor — see note in textured shader.
        return vec4(applyFrameFogAndExposure(shaded, vWorldPos), outAlpha);
    }

    float shininess = mix(96.0, 10.0, roughness);
    shininess = mix(shininess, 128.0, reflectance);
    float spec = pow(max(dot(n, halfDir), 0.0), shininess)
        * uSpecularStrength * (1.0 + reflectance * 2.0)
        * directionalShadow;
    float spec_weight = 0.22 + (1.0 - roughness) * 0.78;
    spec_weight = mix(spec_weight, 1.0, metalness * 0.65);

    float fresnel = pow(1.0 - max(dot(n, viewDir), 0.0), 2.0) * uRimStrength * (1.0 + reflectance * 1.2);

    vec3 diffuse_base = base * (ambientTerm + localTerm + diffuseTerm * (1.0 - metalness * 0.35));
    vec3 spec_color = mix(uSunColor, base, metalness * 0.7);
    vec3 reflect_color = mix(uSkyColor, uSunColor, uReflectionSunWeight) * (reflectance * 0.22 * uEnvironmentSpecularScale);
    vec3 lit = diffuse_base + (spec_color * (spec * spec_weight)) + (uSkyColor * (fresnel * 0.15)) + reflect_color;
    vec3 shaded = prepareFrameShadedColor(
        mix(base, lit, clamp(uLightInfluence, 0.0, 1.0)),
        uBrightness);
    // Keep above-white material energy intact until the frame HDR resolver.
    shaded += materialEmission;
    if (uLightingDebugView > 14.5 && uLightingDebugView < 15.5) {
        return vec4(previewFrameHdr(shaded, vWorldPos), outAlpha);
    }
    if (uLightingDebugView > 15.5 && uLightingDebugView < 16.5) {
        return vec4(falseColorLuminance(applyFrameFogAndExposure(shaded, vWorldPos)), outAlpha);
    }
    if (uLightingDebugView > 16.5 && uLightingDebugView < 17.5) {
        return vec4(falseColorHue(applyFrameFogAndExposure(shaded, vWorldPos)), outAlpha);
    }
    // No floor — see note in textured shader.
    return vec4(applyFrameFogAndExposure(shaded, vWorldPos), outAlpha);
}
#endif
]]

STATIC_DEPTH_SHADER = [[
uniform mat4 uViewRotationMatrix;
uniform mat4 uProjectionMatrix;
uniform vec3 uCameraPos;
uniform float uDepthBias;
]] .. CAMERA_DEPTH_BIAS_GLSL .. [[

#ifdef VERTEX
attribute vec3 VertexNormal;
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vec4 clipPos = uProjectionMatrix * uViewRotationMatrix
        * vec4(vertex_position.xyz - uCameraPos, 1.0);
    clipPos = applyCameraDepthBias(clipPos, uProjectionMatrix, uDepthBias);
    return clipPos;
}
#endif

#ifdef PIXEL
vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords)
{
    return vec4(1.0);
}
#endif
]]

TEXTURED_DEPTH_SHADER = RBX._rigid_mesh_glsl .. [[
uniform mat4 uViewRotationMatrix;
uniform mat4 uProjectionMatrix;
uniform vec3 uCameraPos;
uniform float uDepthBias;
]] .. CAMERA_DEPTH_BIAS_GLSL .. [[

#ifdef VERTEX
attribute vec3 VertexNormal;
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vec4 clipPos = uProjectionMatrix * uViewRotationMatrix
        * vec4(rbxRigidPoint(vertex_position.xyz) - uCameraPos, 1.0);
    clipPos = applyCameraDepthBias(clipPos, uProjectionMatrix, uDepthBias);
    return clipPos;
}
#endif

#ifdef PIXEL
vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords)
{
    return vec4(1.0);
}
#endif
]]

-- Directional-shadow caster programs write light-space depth into an RGB
-- encoded color atlas while a real depth attachment resolves front-most
-- geometry.  Encoding keeps the rgba8 fallback precise enough for large maps;
-- rgba16f hardware uses the same representation and therefore the exact same
-- receiver comparison path
DIRECTIONAL_SHADOW_DEPTH_GLSL = [[
vec3 encodeDirectionalShadowDepth(float depthValue)
{
    float d = clamp(depthValue, 0.0, 0.999999);
    vec3 encoded = fract(d * vec3(1.0, 255.0, 65025.0));
    encoded -= encoded.yzz * vec3(1.0 / 255.0, 1.0 / 255.0, 0.0);
    return encoded;
}
]]

DIRECTIONAL_SHADOW_STATIC_CASTER_SHADER = [[
uniform mat4 uShadowMatrix;
varying float vShadowDepth;

#ifdef VERTEX
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vec4 clipPos = uShadowMatrix * vec4(vertex_position.xyz, 1.0);
    vShadowDepth = clipPos.z / max(abs(clipPos.w), 0.000001) * 0.5 + 0.5;
    return clipPos;
}
#endif

#ifdef PIXEL
]] .. DIRECTIONAL_SHADOW_DEPTH_GLSL .. [[
vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords)
{
    return vec4(encodeDirectionalShadowDepth(vShadowDepth), 1.0);
}
#endif
]]

DIRECTIONAL_SHADOW_INSTANCED_CASTER_SHADER = [[
uniform mat4 uShadowMatrix;
varying float vShadowDepth;

#ifdef VERTEX
attribute vec3 InstancePosition;
attribute vec3 InstanceRight;
attribute vec3 InstanceUp;
attribute vec3 InstanceBack;
attribute vec3 InstanceSize;
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vec3 scaled = vertex_position.xyz * InstanceSize;
    vec3 worldPos = InstancePosition
        + InstanceRight * scaled.x
        + InstanceUp * scaled.y
        + InstanceBack * scaled.z;
    vec4 clipPos = uShadowMatrix * vec4(worldPos, 1.0);
    vShadowDepth = clipPos.z / max(abs(clipPos.w), 0.000001) * 0.5 + 0.5;
    return clipPos;
}
#endif

#ifdef PIXEL
]] .. DIRECTIONAL_SHADOW_DEPTH_GLSL .. [[
vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords)
{
    return vec4(encodeDirectionalShadowDepth(vShadowDepth), 1.0);
}
#endif
]]

DIRECTIONAL_SHADOW_TEXTURED_CASTER_SHADER = RBX._rigid_mesh_glsl .. [[
uniform mat4 uShadowMatrix;
uniform float uShadowAlphaTest;
uniform float uShadowAlphaThreshold;
uniform float uShadowIgnoreTextureAlpha;
uniform float uFlipU;
uniform float uFlipV;
varying float vShadowDepth;
varying float vShadowVertexAlpha;

#ifdef VERTEX
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vec4 clipPos = uShadowMatrix * vec4(rbxRigidPoint(vertex_position.xyz), 1.0);
    vShadowDepth = clipPos.z / max(abs(clipPos.w), 0.000001) * 0.5 + 0.5;
    vShadowVertexAlpha = VertexColor.a;
    return clipPos;
}
#endif

#ifdef PIXEL
]] .. DIRECTIONAL_SHADOW_DEPTH_GLSL .. [[
vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords)
{
    if (uShadowAlphaTest > 0.5) {
        vec2 uv = texture_coords;
        if (uFlipU > 0.5) uv.x = 1.0 - uv.x;
        if (uFlipV > 0.5) uv.y = 1.0 - uv.y;
        float textureAlpha = uShadowIgnoreTextureAlpha > 0.5
            ? 1.0 : Texel(texture, uv).a;
        if (vShadowVertexAlpha * textureAlpha
            < uShadowAlphaThreshold) {
            discard;
        }
    }
    return vec4(encodeDirectionalShadowDepth(vShadowDepth), 1.0);
}
#endif
]]

DIRECTIONAL_SHADOW_INSTANCED_MESH_CASTER_SHADER = [[
uniform mat4 uShadowMatrix;
uniform float uShadowAlphaTest;
uniform float uShadowAlphaThreshold;
uniform float uShadowIgnoreTextureAlpha;
uniform float uFlipU;
uniform float uFlipV;
]] .. INSTANCED_MESH_SHARED_POSE_GLSL .. [[
varying float vShadowDepth;
varying float vShadowVertexAlpha;

#ifdef VERTEX
attribute vec3 InstancePosition;
attribute vec3 InstanceRight;
attribute vec3 InstanceUp;
attribute vec3 InstanceBack;
attribute vec3 InstanceScale;
attribute vec4 InstanceColor;
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vec3 scaled = vertex_position.xyz * InstanceScale;
    vec3 worldOffset =
        InstanceRight * scaled.x
        + InstanceUp * scaled.y
        + InstanceBack * scaled.z;
#ifdef RBX_SHARED_INSTANCE_POSE
    worldOffset = rbxSharedInstancePoseRotate(worldOffset);
#endif
    vec3 worldPos = InstancePosition + worldOffset;
#ifdef RBX_SHARED_INSTANCE_POSE
    worldPos += uSharedPoseTranslation;
#endif
    vec4 clipPos = uShadowMatrix * vec4(worldPos, 1.0);
    vShadowDepth = clipPos.z / max(abs(clipPos.w), 0.000001) * 0.5 + 0.5;
    vShadowVertexAlpha = VertexColor.a * InstanceColor.a;
    return clipPos;
}
#endif

#ifdef PIXEL
]] .. DIRECTIONAL_SHADOW_DEPTH_GLSL .. [[
vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords)
{
    if (uShadowAlphaTest > 0.5) {
        vec2 uv = texture_coords;
        if (uFlipU > 0.5) uv.x = 1.0 - uv.x;
        if (uFlipV > 0.5) uv.y = 1.0 - uv.y;
        float textureAlpha = uShadowIgnoreTextureAlpha > 0.5
            ? 1.0 : Texel(texture, uv).a;
        if (vShadowVertexAlpha * textureAlpha
            < uShadowAlphaThreshold) {
            discard;
        }
    }
    return vec4(encodeDirectionalShadowDepth(vShadowDepth), 1.0);
}
#endif
]]

-- Sky layers use the frame post resolver when a floating-point scene target is
-- active. Direct RGBA8 rendering needs the same exposure/shoulder locally so
-- Atmosphere glare retains hue/detail instead of being framebuffer-clipped
SKY_OUTPUT_FRAME_GLSL = [[
uniform float uSkyFramePostActive;
uniform float uSkyFrameExposure;

vec3 rbxResolveSkyLayerOutput(vec3 hdr)
{
    vec3 outputColor = max(hdr, vec3(0.0));
    if (uSkyFramePostActive > 0.5) {
        return outputColor;
    }
    outputColor *= clamp(uSkyFrameExposure, 0.03125, 32.0);
    return clamp(vec3(1.0) - exp(-outputColor), 0.0, 1.0);
}
]]

SKYBOX_SHADER = ATMOSPHERE_FRAME_GLSL .. SKY_OUTPUT_FRAME_GLSL .. [[
uniform mat4 uViewMatrix;
uniform mat4 uProjectionMatrix;
uniform vec3 uCameraPos;
uniform float uSkyDistance;
uniform vec3 uAtmosphereSunDirection;
// uSkyTimeTint.rgb is the multiplicative tint (dark cool at night, near
// white at noon, warm at sunrise/sunset). uSkyTimeTint.a carries the
// night_factor so the shader can shift toward the night sky color.
uniform vec4 uSkyTimeTint;
// uSkyFaceBlank is 1.0 when this draw call is rendering an intentionally
// blank skybox face (a Sky instance was present but the face property was
// omitted). For blank faces we ignore the texture and emit a solid tint.
uniform float uSkyFaceBlank;
// uSkyBlankColor is the color emitted for blank faces (already pre-tinted
// for ClockTime — dark at night, light at day).
uniform vec3 uSkyBlankColor;
// uSkyExposure compresses the configured skybox texture brightness so the
// daytime cubemap doesn't keep its full saturation at night.
uniform float uSkyExposure;
varying vec3 vSkyDirection;

#ifdef VERTEX
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vSkyDirection = vertex_position.xyz;
    vec3 worldPos = uCameraPos + (vertex_position.xyz * uSkyDistance);
    return uProjectionMatrix * uViewMatrix * vec4(worldPos, 1.0);
}
#endif

#ifdef PIXEL
vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
{
    vec3 sky;
    float skyAlpha = 1.0;
    if (uSkyFaceBlank > 0.5) {
        sky = uSkyBlankColor;
    } else {
        vec4 texel = Texel(tex, texture_coords);
        skyAlpha = texel.a;
        sky = clamp((texel.rgb - 0.50) * 1.08 + 0.50, 0.0, 1.0);
        sky = mix(sky, sky * vec3(0.82, 0.94, 1.08), 0.45);
        sky *= uSkyExposure;
        // Tint the daytime cubemap toward the time-of-day tint. The interpolation
        // is parameterised by the night_factor stored in uSkyTimeTint.a so noon
        // stays bright and midnight collapses into a deep blue.
        sky = mix(sky, sky * uSkyTimeTint.rgb,
            clamp(0.45 + uSkyTimeTint.a * 0.55, 0.0, 1.0));
        sky *= 0.88;
    }
    sky = rbxApplyAtmosphereSky(
        sky, vSkyDirection, uAtmosphereSunDirection);
    sky = rbxResolveSkyLayerOutput(sky);
    return vec4(sky, skyAlpha) * color;
}
#endif
]]

CELESTIAL_SHADER = ATMOSPHERE_FRAME_GLSL .. SKY_OUTPUT_FRAME_GLSL .. [[
uniform mat4 uViewMatrix;
uniform mat4 uProjectionMatrix;
uniform vec3 uCameraPos;
uniform float uSkyDistance;
uniform vec3 uAtmosphereSunDirection;
uniform vec3 uCelestialDir;     // world-space direction toward the body
uniform vec3 uCelestialRight;   // tangent right axis (already scaled by half-size)
uniform vec3 uCelestialUp;      // tangent up axis (already scaled by half-size)
uniform vec4 uCelestialColor;   // rgb multiplier, a = overall opacity
varying vec3 vCelestialDirection;

#ifdef VERTEX
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    // vertex_position.xy is in [-1, 1] for the quad
    vec3 worldOffset = uCelestialDir * uSkyDistance
        + uCelestialRight * vertex_position.x
        + uCelestialUp * vertex_position.y;
    vCelestialDirection = worldOffset;
    vec3 worldPos = uCameraPos + worldOffset;
    return uProjectionMatrix * uViewMatrix * vec4(worldPos, 1.0);
}
#endif

#ifdef PIXEL
vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
{
    vec4 texel = Texel(tex, texture_coords);
    if (texel.a < 0.01) {
        discard;
    }
    vec3 body = texel.rgb * uCelestialColor.rgb * color.rgb;
    body = rbxAttenuateAtmosphereCelestial(
        body, vCelestialDirection, uAtmosphereSunDirection);
    body = rbxResolveSkyLayerOutput(body);
    return vec4(body, texel.a * uCelestialColor.a * color.a);
}
#endif
]]

STARFIELD_SHADER = ATMOSPHERE_FRAME_GLSL .. SKY_OUTPUT_FRAME_GLSL .. [[
uniform mat4 uViewMatrix;
uniform mat4 uProjectionMatrix;
uniform vec3 uCameraPos;
uniform float uSkyDistance;
uniform vec3 uAtmosphereSunDirection;
uniform vec3 uStarColor;
uniform float uStarOpacity;

#ifdef VERTEX
attribute float StarSize;

varying float vSize;
varying vec3 vStarDirection;
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vSize = StarSize;
    vStarDirection = vertex_position.xyz;
    vec3 worldPos = uCameraPos + (vertex_position.xyz * uSkyDistance);
    vec4 clip = uProjectionMatrix * uViewMatrix * vec4(worldPos, 1.0);
    // Use a small fixed-pixel point size so the star is visible regardless
    // of distance to the sky shell.
    gl_PointSize = clamp(StarSize, 1.0, 6.0);
    return clip;
}
#endif

#ifdef PIXEL
varying float vSize;
varying vec3 vStarDirection;
vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
{
    // Soft circular falloff so stars look like points instead of squares.
    vec2 uv = gl_PointCoord - vec2(0.5);
    float d2 = dot(uv, uv);
    if (d2 > 0.25) discard;
    float intensity = 1.0 - smoothstep(0.0, 0.25, d2);
    vec3 star = rbxAttenuateAtmosphereCelestial(
        uStarColor, vStarDirection, uAtmosphereSunDirection);
    star = rbxResolveSkyLayerOutput(star);
    return vec4(star * intensity, intensity * uStarOpacity);
}
#endif
]]

--[[
per-frame dynamic re-bake vertex-table pools: a moving part re-bakes its chunk every frame,
pooling the per-vertex tables kills the dominant move-time GC. active ONLY during
_sync_runtime_part_transforms -- static geometry must keep allocating fresh persistent
tables. safe because a dynamic chunk's CPU vertices upload every frame and are never read
back on a later one
]]
local _dyn_pool_active = false
local _textured_vtx_pool, _textured_vtx_cursor = {}, 0
local _static_vtx_pool, _static_vtx_cursor = {}, 0

function rbx_dynamic_vtx_pool_begin()
    _textured_vtx_cursor = 0
    _static_vtx_cursor = 0
    _dyn_pool_active = true
end

function rbx_dynamic_vtx_pool_end()
    _dyn_pool_active = false
end

-- pack float vertex tables into bytedata for setVertices: skips love's per-field table
-- marshalling in newMesh, the single hottest line of a big map's load. nil w/o ffi
local pack_ffi_ok, pack_ffi = pcall(require, "ffi")
if pack_ffi_ok and type(pack_ffi) ~= "table" then
    pack_ffi_ok = false
    pack_ffi = nil
end

--[[ textured batches keep their 20-float vertices together until upload
grow the buffer as needed and reuse the packed rows ]]
local FLAT_VERTEX_START_FLOATS = 20 * 64

local function new_flat_vertex_buffer(cap_floats)
    if not love.data or not love.data.newByteData then
        return nil
    end
    local ok, byte_data = pcall(love.data.newByteData, cap_floats * 4)
    if not ok or not byte_data or not byte_data.getFFIPointer then
        return nil
    end
    local ptr_ok, pointer = pcall(byte_data.getFFIPointer, byte_data)
    if not ptr_ok or pointer == nil then
        return nil
    end
    return byte_data, pack_ffi.cast("float*", pointer)
end

function rbx_create_flat_vertex_list()
    if _dyn_pool_active or not pack_ffi_ok then
        return nil
    end
    local byte_data, floats = new_flat_vertex_buffer(FLAT_VERTEX_START_FLOATS)
    if not byte_data then
        return nil
    end
    return {
        vdata = byte_data,
        vbuf = floats,
        vbuf_cap = FLAT_VERTEX_START_FLOATS,
        vbuf_n = 0,
    }
end

-- kept out of the push hot loop: growth is rare. single-step jump to `need` (not repeated
-- doubling) so bulk appends (mega merge) don't churn intermediate buffers
local function grow_flat_vertex_list(vertices, need_floats)
    local cap = math.max(vertices.vbuf_cap * 2, need_floats)
    local byte_data, floats = new_flat_vertex_buffer(cap)
    if not byte_data then
        error("flat vertex buffer grow failed (" .. tostring(cap * 4) .. " bytes)")
    end
    pack_ffi.copy(floats, vertices.vbuf, vertices.vbuf_n * 4)
    vertices.vdata:release() -- C-heap payload back immediately, not at next GC
    vertices.vdata = byte_data
    vertices.vbuf = floats
    vertices.vbuf_cap = cap
    return floats
end

-- vertex count for either representation, flat lists are always 20-component textured
function rbx_vertex_list_count(vertices)
    if type(vertices) ~= "table" then
        return 0
    end
    if vertices.vbuf ~= nil then
        return vertices.vbuf_n / 20
    end
    return #vertices
end

-- flat->flat append for the mega merge (both sides are flat: mode is constant per build)
function rbx_flat_vertex_list_append(target, source)
    local n = target.vbuf_n
    local add = source.vbuf_n
    if add <= 0 then
        return
    end
    if n + add > target.vbuf_cap then
        grow_flat_vertex_list(target, n + add)
    end
    pack_ffi.copy(target.vbuf + n, source.vbuf, add * 4)
    target.vbuf_n = n + add
end

-- last-resort bridge for consumers that need per-vertex tables (ByteData alloc failure)
function rbx_flat_vertex_list_to_tables(vertices)
    local buf = vertices.vbuf
    local out = {}
    local offset = 0
    for i = 1, vertices.vbuf_n / 20 do
        local vt = {}
        for c = 1, 20 do
            vt[c] = buf[offset]
            offset = offset + 1
        end
        out[i] = vt
    end
    return out
end

-- reuse-path upload for either representation (Mesh:setVertices accepts a Data object)
local shadow_array_vertices=require('engine/graphics/rbx/runtime/shadow_array')
function rbx_set_mesh_vertices(mesh, vertices)
    shadow_array_vertices.invalidate(mesh)
    if vertices.vbuf ~= nil then
        local packed = rbx_pack_vertices_bytedata(vertices, 20)
        if not packed then
            return false
        end
        local ok = pcall(mesh.setVertices, mesh, packed)
        packed:release()
        return ok
    end
    return pcall(mesh.setVertices, mesh, vertices)
end

function rbx_pack_vertices_bytedata(vertices, components)
    if not pack_ffi_ok or not love.data or not love.data.newByteData then
        return nil
    end
    local flat = vertices.vbuf
    local count = flat ~= nil and (vertices.vbuf_n / components) or #vertices
    if count == 0 then
        return nil
    end
    local ok, byte_data = pcall(love.data.newByteData, count * components * 4)
    if not ok or not byte_data or not byte_data.getFFIPointer then
        return nil
    end
    local ptr_ok, pointer = pcall(byte_data.getFFIPointer, byte_data)
    if not ptr_ok or pointer == nil then
        return nil
    end
    if flat ~= nil then
        -- flat lists only exist with components == 20 (textured batch path)
        pack_ffi.copy(pointer, flat, vertices.vbuf_n * 4)
        return byte_data
    end
    local floats = pack_ffi.cast("float*", pointer)
    local offset = 0
    for i = 1, count do
        local vertex = vertices[i]
        for c = 1, components do
            floats[offset] = vertex[c] or 0
            offset = offset + 1
        end
    end
    return byte_data
end

--[[
instanced mesh support -------------------------------------------------------------

MeshId assets share mesh_data table identity via the asset cache, but embedded CSG meshes
are parsed per part (distinct tables, identical content -- 85 unions can share 22 signatures),
so the signature has to be a content hash, cached on the mesh_data table
]]
function rbx_get_gpu_mesh_colors(mesh_data)
    if type(mesh_data) ~= "table" then
        return nil
    end
    local authored = mesh_data.colors
    if type(authored) ~= "table" or #authored == 0 then
        return nil
    end
    local linear_gpu_space = runtime_coords.gpu_color_space_is_linear()
    if mesh_data._gpu_colors_source == authored
        and mesh_data._gpu_colors_count == #authored
        and mesh_data._gpu_colors_linear_space == linear_gpu_space
        and type(mesh_data._gpu_colors) == "table" then
        return mesh_data._gpu_colors
    end

    -- Vertex colors are authored bytes just like Color3 values. cache their render
    -- representation on the immutable decoded mesh so repeated parts pay for the
    -- transfer function once, rather than once per bake or frame
    local gpu_colors = {}
    for index = 1, #authored, 4 do
        gpu_colors[index] = authored_srgb_to_gpu(clamp(authored[index] or 1, 0, 1))
        gpu_colors[index + 1] = authored_srgb_to_gpu(clamp(authored[index + 1] or 1, 0, 1))
        gpu_colors[index + 2] = authored_srgb_to_gpu(clamp(authored[index + 2] or 1, 0, 1))
        gpu_colors[index + 3] = clamp(authored[index + 3] or 1, 0, 1)
    end
    mesh_data._gpu_colors = gpu_colors
    mesh_data._gpu_colors_source = authored
    mesh_data._gpu_colors_count = #authored
    mesh_data._gpu_colors_linear_space = linear_gpu_space
    return gpu_colors
end

function rbx_mesh_geometry_signature(mesh_data)
    if type(mesh_data) ~= "table" then
        return nil
    end
    local cached = mesh_data._geo_signature
    if cached then
        return cached
    end
    local positions = mesh_data.positions
    if type(positions) ~= "table" or #positions == 0 then
        return nil
    end
    --[[ must cover every baked stream (positions, normals, uvs, colors): same positions +
    different uvs must NOT alias into one group, or every instance renders the first part's
    streams. two hashes w/ different multipliers -- one 32-bit hash over ~96 samples/stream
    left a real collision window, and a collision silently aliases the whole group ]]
    local hash_a, hash_b
    local function fold_stream(values, quantize)
        if type(values) ~= "table" or #values == 0 then
            hash_a = (hash_a * 31 + 1) % 4294967296
            hash_b = (hash_b * 37 + 1) % 4294967296
            return 0
        end
        local count = #values
        hash_a = (hash_a * 31 + count) % 4294967296
        hash_b = (hash_b * 37 + count) % 4294967296
        local step = math.max(1, math.floor(count / 96))
        for i = 1, count, step do
            local q = math.floor((values[i] or 0) * quantize + 0.5)
            hash_a = (hash_a * 31 + q) % 4294967296
            hash_b = (hash_b * 37 + q) % 4294967296
        end
        return count
    end
    local n = #positions
    hash_a = n * 2654435761 % 4294967296
    hash_b = n * 40503 % 4294967296
    fold_stream(positions, 1024)
    local n_normals = fold_stream(mesh_data.normals, 512)
    local n_uvs = fold_stream(mesh_data.uvs, 4096)
    local n_colors = fold_stream(mesh_data.colors, 255)
    local signature = "g" .. tostring(hash_a) .. ":" .. tostring(hash_b)
        .. ":" .. tostring(n) .. ":" .. tostring(n_normals)
        .. ":" .. tostring(n_uvs) .. ":" .. tostring(n_colors)
    mesh_data._geo_signature = signature
    return signature
end

--[[
shared LOCAL-space geometry ByteData for an instanced group. 12 floats: position, normal,
uv, color. positions/normals/uvs stay RAW -- scale/mirror/flips are per-instance/per-group
state. color = linearized mesh vertex colors if the color mode uses them, else white
(shader multiplies by linear InstanceColor). one ByteData per (signature, color-mode)
]]
function rbx_build_instanced_mesh_geometry(mesh_data, use_vertex_colors)
    if not pack_ffi_ok or not love.data or not love.data.newByteData then
        return nil, 0
    end
    local positions = mesh_data.positions or {}
    local normals = mesh_data.normals or {}
    local uvs = mesh_data.uvs or {}
    local colors = use_vertex_colors and rbx_get_gpu_mesh_colors(mesh_data) or nil
    local vertex_count = math.floor(#positions / 3)
    if vertex_count < 3 then
        return nil, 0
    end
    local ok, byte_data = pcall(love.data.newByteData, vertex_count * 12 * 4)
    if not ok or not byte_data or not byte_data.getFFIPointer then
        return nil, 0
    end
    local ptr_ok, pointer = pcall(byte_data.getFFIPointer, byte_data)
    if not ptr_ok or pointer == nil then
        return nil, 0
    end
    local floats = pack_ffi.cast("float*", pointer)
    local offset = 0
    for vertex_index = 1, vertex_count do
        local pidx = (vertex_index - 1) * 3 + 1
        local uidx = (vertex_index - 1) * 2 + 1
        local cidx = (vertex_index - 1) * 4 + 1
        floats[offset] = positions[pidx] or 0
        floats[offset + 1] = positions[pidx + 1] or 0
        floats[offset + 2] = positions[pidx + 2] or 0
        floats[offset + 3] = normals[pidx] or 0
        floats[offset + 4] = normals[pidx + 1] or 1
        floats[offset + 5] = normals[pidx + 2] or 0
        floats[offset + 6] = uvs[uidx] or 0
        floats[offset + 7] = uvs[uidx + 1] or 0
        if colors then
            floats[offset + 8] = colors[cidx] or 1
            floats[offset + 9] = colors[cidx + 1] or 1
            floats[offset + 10] = colors[cidx + 2] or 1
            floats[offset + 11] = colors[cidx + 3] or 1
        else
            floats[offset + 8] = 1
            floats[offset + 9] = 1
            floats[offset + 10] = 1
            floats[offset + 11] = 1
        end
        offset = offset + 12
    end
    return byte_data, vertex_count
end

--[[
projected-uv variant: 12-float layout + a 13th float = baked per-triangle face id (csg
normal-id order). uv slots still written even though the projected shader overrides
VaryingTexCoord, to keep the packing loop shape
]]
function rbx_build_instanced_projected_geometry(mesh_data, use_vertex_colors, face_ids)
    if not pack_ffi_ok or not love.data or not love.data.newByteData then
        return nil, 0
    end
    local positions = mesh_data.positions or {}
    local normals = mesh_data.normals or {}
    local uvs = mesh_data.uvs or {}
    local colors = use_vertex_colors and rbx_get_gpu_mesh_colors(mesh_data) or nil
    local vertex_count = math.floor(#positions / 3)
    if vertex_count < 3 or type(face_ids) ~= "table" or #face_ids < vertex_count then
        return nil, 0
    end
    local ok, byte_data = pcall(love.data.newByteData, vertex_count * 13 * 4)
    if not ok or not byte_data or not byte_data.getFFIPointer then
        return nil, 0
    end
    local ptr_ok, pointer = pcall(byte_data.getFFIPointer, byte_data)
    if not ptr_ok or pointer == nil then
        return nil, 0
    end
    local floats = pack_ffi.cast("float*", pointer)
    local offset = 0
    for vertex_index = 1, vertex_count do
        local pidx = (vertex_index - 1) * 3 + 1
        local uidx = (vertex_index - 1) * 2 + 1
        local cidx = (vertex_index - 1) * 4 + 1
        floats[offset] = positions[pidx] or 0
        floats[offset + 1] = positions[pidx + 1] or 0
        floats[offset + 2] = positions[pidx + 2] or 0
        floats[offset + 3] = normals[pidx] or 0
        floats[offset + 4] = normals[pidx + 1] or 1
        floats[offset + 5] = normals[pidx + 2] or 0
        floats[offset + 6] = uvs[uidx] or 0
        floats[offset + 7] = uvs[uidx + 1] or 0
        if colors then
            floats[offset + 8] = colors[cidx] or 1
            floats[offset + 9] = colors[cidx + 1] or 1
            floats[offset + 10] = colors[cidx + 2] or 1
            floats[offset + 11] = colors[cidx + 3] or 1
        else
            floats[offset + 8] = 1
            floats[offset + 9] = 1
            floats[offset + 10] = 1
            floats[offset + 11] = 1
        end
        floats[offset + 12] = face_ids[vertex_index] or 0
        offset = offset + 13
    end
    return byte_data, vertex_count
end

-- exact GPU-row indexing for repeated opaque meshes.  the decoded mesh arrays are
-- flat triangle lists, but many entries repeat a vertex at triangle boundaries
-- Deduplicating the Lua doubles directly is subtly wrong: LOVE uploads these
-- attributes as float32, so two different doubles can become the same GPU value
-- build the key from the actual float32 bytes instead.  the whole uploaded row is
-- included, which preserves hard-normal, UV, GPU-colour, and projected-face seams
--
-- Tangents are deliberately absent from this key because neither repeated-mesh
-- vertex format uploads them.  the projected-material eligibility check also rejects
-- tangent-bearing meshes.  if a future instanced format adds tangents, its uploaded
-- tangent/handedness attributes must be appended here before that format is enabled
local function finite_instanced_mesh_component(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

function rbx_instanced_mesh_index_size(unique_vertex_count)
    unique_vertex_count = math.max(
        0, math.floor(tonumber(unique_vertex_count) or 0))
    return unique_vertex_count <= 65535 and 2 or 4
end

function rbx_build_indexed_instanced_mesh_geometry(
    mesh_data, use_vertex_colors, face_ids)
    if not pack_ffi_ok or type(pack_ffi.string) ~= "function" then
        return nil, "ffi_unavailable"
    end
    if type(mesh_data) ~= "table" then
        return nil, "invalid_mesh"
    end

    local positions = mesh_data.positions or {}
    local normals = mesh_data.normals or {}
    local uvs = mesh_data.uvs or {}
    local colors = use_vertex_colors and rbx_get_gpu_mesh_colors(mesh_data) or nil
    local source_vertex_count = math.floor(#positions / 3)
    local projected = face_ids ~= nil
    local component_count = projected and 13 or 12
    local vertex_stride_bytes = component_count * 4
    if source_vertex_count < 3 then
        return nil, "empty_geometry", {
            source_vertex_count = source_vertex_count,
            component_count = component_count,
        }
    end
    if projected
        and (type(face_ids) ~= "table"
            or #face_ids < source_vertex_count) then
        return nil, "projected_face_ids_missing", {
            source_vertex_count = source_vertex_count,
            component_count = component_count,
        }
    end

    local key_floats = pack_ffi.new("float[13]")
    local vertices = {}
    local indices = {}
    local vertex_by_key = {}

    local function set_component(index, value, fallback)
        if value == nil then
            value = fallback
        end
        if not finite_instanced_mesh_component(value) then
            return false
        end
        key_floats[index] = value
        -- Lua numbers are doubles while the vertex format is float32. a finite
        -- double can still overflow to +/-inf during the actual upload cast
        -- (for example 1e300), so validate the value that was written into the
        -- key buffer rather than only the source value
        return finite_instanced_mesh_component(tonumber(key_floats[index]))
    end

    for source_index = 1, source_vertex_count do
        local pidx = (source_index - 1) * 3 + 1
        local uidx = (source_index - 1) * 2 + 1
        local cidx = (source_index - 1) * 4 + 1
        local valid =
            set_component(0, positions[pidx], 0)
            and set_component(1, positions[pidx + 1], 0)
            and set_component(2, positions[pidx + 2], 0)
            and set_component(3, normals[pidx], 0)
            and set_component(4, normals[pidx + 1], 1)
            and set_component(5, normals[pidx + 2], 0)
            and set_component(6, uvs[uidx], 0)
            and set_component(7, uvs[uidx + 1], 0)
            and set_component(8, colors and colors[cidx] or nil, 1)
            and set_component(9, colors and colors[cidx + 1] or nil, 1)
            and set_component(10, colors and colors[cidx + 2] or nil, 1)
            and set_component(11, colors and colors[cidx + 3] or nil, 1)
        if projected then
            valid = valid
                and set_component(12, face_ids[source_index], 0)
        end
        if not valid then
            return nil, "non_finite_attribute", {
                source_vertex_count = source_vertex_count,
                component_count = component_count,
                source_vertex_index = source_index,
            }
        end

        local key = pack_ffi.string(key_floats, vertex_stride_bytes)
        local vertex_index = vertex_by_key[key]
        if vertex_index == nil then
            vertex_index = #vertices + 1
            local vertex = {}
            -- copy the float32 values, not the source doubles.  Besides making
            -- diagnostics truthful, this guarantees the retained row is exactly
            -- the row whose bytes were hashed above
            for component = 1, component_count do
                vertex[component] = tonumber(key_floats[component - 1])
            end
            vertices[vertex_index] = vertex
            vertex_by_key[key] = vertex_index
        end
        indices[source_index] = vertex_index
    end

    local vertex_count = #vertices
    local indices_tsize = rbx_instanced_mesh_index_size(vertex_count)
    local flat_vertex_bytes = source_vertex_count * vertex_stride_bytes
    local compact_vertex_bytes = vertex_count * vertex_stride_bytes
    local index_bytes = source_vertex_count * indices_tsize
    local indexed_bytes = compact_vertex_bytes + index_bytes
    if indexed_bytes >= flat_vertex_bytes then
        return nil, "not_smaller", {
            source_vertex_count = source_vertex_count,
            vertex_count = vertex_count,
            index_count = source_vertex_count,
            component_count = component_count,
            vertex_stride_bytes = vertex_stride_bytes,
            indices_tsize = indices_tsize,
            flat_vertex_bytes = flat_vertex_bytes,
            compact_vertex_bytes = compact_vertex_bytes,
            index_bytes = index_bytes,
            indexed_bytes = indexed_bytes,
        }
    end

    return {
        vertices = vertices,
        indices = indices,
        vertex_count = vertex_count,
        source_vertex_count = source_vertex_count,
        index_count = source_vertex_count,
        component_count = component_count,
        vertex_stride_bytes = vertex_stride_bytes,
        indices_tsize = indices_tsize,
        flat_vertex_bytes = flat_vertex_bytes,
        compact_vertex_bytes = compact_vertex_bytes,
        index_bytes = index_bytes,
        indexed_bytes = indexed_bytes,
        bytes_saved = flat_vertex_bytes - indexed_bytes,
        projected = projected,
    }
end

-- pack a part's 27-float instance row into a reusable 27-slot table. slots mirror the shader
-- attrs: position(3) right(3) up(3) back(3) local_scale(3) rgba(4) misc(reflectance,0,0,0)
-- contact ao(top,bottom,side,overall)
function rbx_pack_mesh_instance_row(row, transform, color_r, color_g, color_b, alpha,
                                    reflectance, ao_top, ao_bottom, ao_side, ao_overall)
    local local_scale_x = transform.local_scale_x or ((transform.mesh_axis_x or 1) * transform.scale_x)
    local local_scale_y = transform.local_scale_y or transform.scale_y
    local local_scale_z = transform.local_scale_z or ((transform.mesh_axis_z or 1) * transform.scale_z)
    row[1] = transform.px
    row[2] = transform.py
    row[3] = transform.pz
    row[4] = transform.rx
    row[5] = transform.ry
    row[6] = transform.rz
    row[7] = transform.ux
    row[8] = transform.uy
    row[9] = transform.uz
    row[10] = transform.bx
    row[11] = transform.by
    row[12] = transform.bz
    row[13] = local_scale_x
    row[14] = local_scale_y
    row[15] = local_scale_z
    row[16] = color_r
    row[17] = color_g
    row[18] = color_b
    row[19] = alpha
    row[20] = reflectance or 0
    row[21] = 0
    row[22] = 0
    row[23] = 0
    row[24] = ao_top or 0
    row[25] = ao_bottom or 0
    row[26] = ao_side or 0
    row[27] = ao_overall or 0
    return row
end

--[[
fast-rebake for single-part dynamic mesh chunks: re-running the full lua bake per frame cost
3-6ms on a big animated mesh. snapshot the ALREADY-BAKED world verts (pipeline output, so
mirror/uv/winding rules survive by construction) + the pose they were baked at, then each
move applies the rigid delta (pose x baked-pose-inverse) in an ffi loop. uv/color/reflectance
/ao are copied once and never touched. scale/geometry changes bump part._render_prop_revision
via the property-write hook = full re-bake
]]
-- the contiguous loop is cheaper under the JIT, select once before snapshots
-- are created, with no status check or wrapper on that path
local reuse_snapshot_rows = type(jit) == "table" and type(jit.status) == "function" and jit.status() == false

-- a row can share arithmetic only when every original float has identical bits
local function snapshot_duplicate_offsets(src, dst, count)
    if count < 64 or count > 65536 then
        return nil
    end
    local bits = pack_ffi.cast("uint32_t*", src)
    for lane = 0, count * 20 - 1 do
        -- Inspect raw exponents: reading an unsupported NaN as a Lua number can
        -- itself change the original failure boundary
        if bits[lane] % 2147483648 >= 2139095040 then
            return nil
        end
    end
    local first_by_bytes, unique, duplicates = {}, {}, {}
    for offset = 0, (count - 1) * 20, 20 do
        local key = pack_ffi.string(src + offset, 80)
        local first = first_by_bytes[key]
        if first == nil then
            first_by_bytes[key] = offset
            unique[#unique + 1] = offset
        else
            duplicates[#duplicates + 1] = offset
            duplicates[#duplicates + 1] = first
        end
    end
    -- sparse reuse would add an indirect lookup to nearly every original row
    if #duplicates < count / 2 then
        return nil
    end
    local unique_offsets = pack_ffi.new("uint32_t[?]", #unique)
    local duplicate_offsets = pack_ffi.new("uint32_t[?]", #duplicates)
    for i = 1, #unique do unique_offsets[i - 1] = unique[i] end
    for i = 1, #duplicates do duplicate_offsets[i - 1] = duplicates[i] end
    -- Lua tables retain pointer objects, indexing an FFI pointer array would
    -- box fresh cdata on every interpreted pose. dst_data owns their storage
    local duplicate_pointers = {}
    for i = 1, #duplicates do duplicate_pointers[i] = dst + duplicates[i] end
    -- Rotation-only vectors share the same arithmetic across all three roles;
    -- positions keep their separate translation terms and original row order
    local rotation_first, rotations, copies = {}, {}, {}
    local lanes = {3, 13, 16}
    for i = 1, #unique do
        for _, lane in ipairs(lanes) do
            local offset = unique[i] + lane
            local key = pack_ffi.string(src + offset, 12)
            local first = rotation_first[key]
            if first == nil then
                rotation_first[key] = offset
                rotations[#rotations + 1] = offset
            else
                copies[#copies + 1] = offset
                copies[#copies + 1] = first
            end
        end
    end
    local rotation_offsets, rotation_count, rotation_pointers, rotation_duplicate_count
    if #copies >= #unique * 3 / 2 then
        rotation_offsets = pack_ffi.new("uint32_t[?]", #rotations)
        for i = 1, #rotations do rotation_offsets[i - 1] = rotations[i] end
        rotation_pointers = {}
        for i = 1, #copies do rotation_pointers[i] = dst + copies[i] end
        rotation_count, rotation_duplicate_count = #rotations, #copies / 2
    end
    return unique_offsets, duplicate_offsets, #unique, #duplicates / 2, duplicate_pointers,
        rotation_offsets, rotation_count, rotation_pointers, rotation_duplicate_count
end

function rbx_snapshot_item_vertices(item)
    if not pack_ffi_ok or not love.data or not love.data.newByteData then
        return nil
    end
    local vertices = item and item.cpu_vertices
    if type(vertices) ~= "table" then
        return nil
    end
    local flat = vertices.vbuf
    local count = flat ~= nil and (vertices.vbuf_n / 20) or #vertices
    if count == 0 then
        return nil
    end
    local src = pack_ffi.new("float[?]", count * 20)
    if flat ~= nil then
        pack_ffi.copy(src, flat, count * 20 * 4)
    else
        local offset = 0
        for i = 1, count do
            local vertex = vertices[i]
            for c = 1, 20 do
                src[offset] = vertex[c] or 0
                offset = offset + 1
            end
        end
    end
    local ok, byte_data = pcall(love.data.newByteData, count * 80)
    if not ok or not byte_data or not byte_data.getFFIPointer then
        return nil
    end
    local ptr_ok, pointer = pcall(byte_data.getFFIPointer, byte_data)
    if not ptr_ok or pointer == nil then
        return nil
    end
    local dst = pack_ffi.cast("float*", pointer)
    pack_ffi.copy(dst, src, count * 80)
    -- initialize fixed attributes through the original scalar stores once;
    -- later poses own only the position, normal, tangent and bitangent lanes
    for offset = 0, (count - 1) * 20, 20 do
        dst[offset + 6] = src[offset + 6]
        dst[offset + 7] = src[offset + 7]
        dst[offset + 8] = src[offset + 8]
        dst[offset + 9] = src[offset + 9]
        dst[offset + 10] = src[offset + 10]
        dst[offset + 11] = src[offset + 11]
        dst[offset + 12] = src[offset + 12]
        dst[offset + 19] = src[offset + 19]
    end
    local unique_offsets, duplicate_offsets, unique_count, duplicate_count, duplicate_pointers
    local rotation_offsets, rotation_count, rotation_pointers, rotation_duplicate_count
    if reuse_snapshot_rows then
        local reuse_ok
        reuse_ok, unique_offsets, duplicate_offsets, unique_count, duplicate_count, duplicate_pointers,
            rotation_offsets, rotation_count, rotation_pointers, rotation_duplicate_count =
            pcall(snapshot_duplicate_offsets, src, dst, count)
        if not reuse_ok then
            unique_offsets, duplicate_offsets, unique_count, duplicate_count, duplicate_pointers = nil, nil, nil, nil, nil
            rotation_offsets, rotation_count, rotation_pointers, rotation_duplicate_count = nil, nil, nil, nil
        end
    end
    return {
        src = src,
        dst_data = byte_data,
        dst = dst,
        count = count,
        unique_offsets = unique_offsets,
        duplicate_offsets = duplicate_offsets,
        unique_count = unique_count,
        duplicate_count = duplicate_count,
        duplicate_pointers = duplicate_pointers,
        rotation_offsets = rotation_offsets,
        rotation_count = rotation_count,
        rotation_pointers = rotation_pointers,
        rotation_duplicate_count = rotation_duplicate_count,
    }
end

-- positions get the full transform, normals/tangents/bitangents rotation only
local function fast_bake_contiguous(snapshot,
                             m00, m01, m02,
                             m10, m11, m12,
                             m20, m21, m22,
                             tx, ty, tz)
    local src, dst = snapshot.src, snapshot.dst
    local offset = 0
    for _ = 1, snapshot.count do
        local x, y, z = src[offset], src[offset + 1], src[offset + 2]
        dst[offset] = m00 * x + m01 * y + m02 * z + tx
        dst[offset + 1] = m10 * x + m11 * y + m12 * z + ty
        dst[offset + 2] = m20 * x + m21 * y + m22 * z + tz
        local nx, ny, nz = src[offset + 3], src[offset + 4], src[offset + 5]
        dst[offset + 3] = m00 * nx + m01 * ny + m02 * nz
        dst[offset + 4] = m10 * nx + m11 * ny + m12 * nz
        dst[offset + 5] = m20 * nx + m21 * ny + m22 * nz
        local tx1, ty1, tz1 = src[offset + 13], src[offset + 14], src[offset + 15]
        dst[offset + 13] = m00 * tx1 + m01 * ty1 + m02 * tz1
        dst[offset + 14] = m10 * tx1 + m11 * ty1 + m12 * tz1
        dst[offset + 15] = m20 * tx1 + m21 * ty1 + m22 * tz1
        local bx1, by1, bz1 = src[offset + 16], src[offset + 17], src[offset + 18]
        dst[offset + 16] = m00 * bx1 + m01 * by1 + m02 * bz1
        dst[offset + 17] = m10 * bx1 + m11 * by1 + m12 * bz1
        dst[offset + 18] = m20 * bx1 + m21 * by1 + m22 * bz1
        offset = offset + 20
    end
end

local function fast_bake_duplicates(snapshot,
                             m00, m01, m02,
                             m10, m11, m12,
                             m20, m21, m22,
                             tx, ty, tz)
    local unique_offsets = snapshot.unique_offsets
    local huge = math.huge
    if not unique_offsets
        or type(m00) ~= "number" or type(m01) ~= "number" or type(m02) ~= "number"
        or type(m10) ~= "number" or type(m11) ~= "number" or type(m12) ~= "number"
        or type(m20) ~= "number" or type(m21) ~= "number" or type(m22) ~= "number"
        or type(tx) ~= "number" or type(ty) ~= "number" or type(tz) ~= "number"
        or not (m00 > -huge and m00 < huge and m01 > -huge and m01 < huge and m02 > -huge and m02 < huge
            and m10 > -huge and m10 < huge and m11 > -huge and m11 < huge and m12 > -huge and m12 < huge
            and m20 > -huge and m20 < huge and m21 > -huge and m21 < huge and m22 > -huge and m22 < huge
            and tx > -huge and tx < huge and ty > -huge and ty < huge and tz > -huge and tz < huge) then
        return fast_bake_contiguous(snapshot,
            m00, m01, m02, m10, m11, m12, m20, m21, m22, tx, ty, tz)
    end
    local src, dst = snapshot.src, snapshot.dst
    local rotation_offsets = snapshot.rotation_offsets
    if rotation_offsets then
        for i = 0, snapshot.unique_count - 1 do
            local offset = unique_offsets[i]
            local x, y, z = src[offset], src[offset + 1], src[offset + 2]
            dst[offset] = m00 * x + m01 * y + m02 * z + tx
            dst[offset + 1] = m10 * x + m11 * y + m12 * z + ty
            dst[offset + 2] = m20 * x + m21 * y + m22 * z + tz
        end
        for i = 0, snapshot.rotation_count - 1 do
            local offset = rotation_offsets[i]
            local nx, ny, nz = src[offset], src[offset + 1], src[offset + 2]
            dst[offset] = m00 * nx + m01 * ny + m02 * nz
            dst[offset + 1] = m10 * nx + m11 * ny + m12 * nz
            dst[offset + 2] = m20 * nx + m21 * ny + m22 * nz
        end
        local rotations = snapshot.rotation_pointers
        for i = 1, snapshot.rotation_duplicate_count * 2, 2 do
            pack_ffi.copy(rotations[i], rotations[i + 1], 12)
        end
    else
        for i = 0, snapshot.unique_count - 1 do
            local offset = unique_offsets[i]
            local x, y, z = src[offset], src[offset + 1], src[offset + 2]
            dst[offset] = m00 * x + m01 * y + m02 * z + tx
            dst[offset + 1] = m10 * x + m11 * y + m12 * z + ty
            dst[offset + 2] = m20 * x + m21 * y + m22 * z + tz
            local nx, ny, nz = src[offset + 3], src[offset + 4], src[offset + 5]
            dst[offset + 3] = m00 * nx + m01 * ny + m02 * nz
            dst[offset + 4] = m10 * nx + m11 * ny + m12 * nz
            dst[offset + 5] = m20 * nx + m21 * ny + m22 * nz
            local tx1, ty1, tz1 = src[offset + 13], src[offset + 14], src[offset + 15]
            dst[offset + 13] = m00 * tx1 + m01 * ty1 + m02 * tz1
            dst[offset + 14] = m10 * tx1 + m11 * ty1 + m12 * tz1
            dst[offset + 15] = m20 * tx1 + m21 * ty1 + m22 * tz1
            local bx1, by1, bz1 = src[offset + 16], src[offset + 17], src[offset + 18]
            dst[offset + 16] = m00 * bx1 + m01 * by1 + m02 * bz1
            dst[offset + 17] = m10 * bx1 + m11 * by1 + m12 * bz1
            dst[offset + 18] = m20 * bx1 + m21 * by1 + m22 * bz1
        end
    end
    local pointers = snapshot.duplicate_pointers
    for i = 1, snapshot.duplicate_count * 2, 2 do
        pack_ffi.copy(pointers[i], pointers[i + 1], 80)
    end
end

rbx_fast_bake_apply = reuse_snapshot_rows and fast_bake_duplicates or fast_bake_contiguous

build_static_mesh = function(renderer, instance_vertices, source_vertices, instance_part_ids)
    if #instance_vertices == 0 then
        return nil
    end

    local local_vertices = source_vertices or renderer._cube_vertices
    local inst_count = #instance_vertices
    local per_instance = #local_vertices
    local total = inst_count * per_instance

    -- Opt-in correctness flag (renderer option `accurate_mesh_normals`). Defaults
    -- off so existing maps keep their current shading until the change has been
    -- eyeballed, see the normal-transform note in the vertex loop below
    local accurate_normals = renderer.accurate_mesh_normals == true

    -- FFI-direct path for load-time builds: floats go straight into the ByteData,
    -- skipping the per-vertex Lua tables (~2.3M dead tables on a 60k-part map, a
    -- top contributor to the load's GC burst). the pool/table paths remain for
    -- dynamic re-bakes and no-FFI platforms
    local direct_floats, direct_bytedata
    if not _dyn_pool_active and pack_ffi_ok and love.data and love.data.newByteData then
        local bd_ok, bd = pcall(love.data.newByteData, total * 12 * 4)
        if bd_ok and bd and bd.getFFIPointer then
            local ptr_ok, ptr = pcall(bd.getFFIPointer, bd)
            if ptr_ok and ptr ~= nil then
                direct_bytedata = bd
                direct_floats = pack_ffi.cast("float*", ptr)
            end
        end
    end

    local output = (not direct_floats) and {} or nil
    local doff = 0
    local vertex_alpha_is_one = true

    for i = 1, #instance_vertices do
        local inst = instance_vertices[i]
        local px, py, pz = inst[1], inst[2], inst[3]
        local rx, ry, rz = inst[4], inst[5], inst[6]
        local ux, uy, uz = inst[7], inst[8], inst[9]
        local bx, by, bz = inst[10], inst[11], inst[12]
        local sx, sy, sz = inst[13], inst[14], inst[15]
        local cr, cg, cb, ca = inst[16], inst[17], inst[18], inst[19]
        vertex_alpha_is_one = vertex_alpha_is_one and ca == 1
        local reflectance = inst[20] or 0
        local contact_top = inst[21] or 0
        local contact_bottom = inst[22] or 0
        local contact_side = inst[23] or 0
        local contact_overall = inst[24] or 0

        -- under nonuniform scale, normals use the inverse transpose
        -- divide by each local scale before applying the part rotation
        local nsx, nsy, nsz = 1, 1, 1
        if accurate_normals then
            if sx > 1e-8 or sx < -1e-8 then nsx = 1 / sx end
            if sy > 1e-8 or sy < -1e-8 then nsy = 1 / sy end
            if sz > 1e-8 or sz < -1e-8 then nsz = 1 / sz end
        end

        for j = 1, #local_vertices do
            local source = local_vertices[j]

            local lx = source[1] * sx
            local ly = source[2] * sy
            local lz = source[3] * sz

            local world_x = px + rx * lx + ux * ly + bx * lz
            local world_y = py + ry * lx + uy * ly + by * lz
            local world_z = pz + rz * lx + uz * ly + bz * lz

            local snx = source[4] * nsx
            local sny = source[5] * nsy
            local snz = source[6] * nsz

            local nx = rx * snx + ux * sny + bx * snz
            local ny = ry * snx + uy * sny + by * snz
            local nz = rz * snx + uz * sny + bz * snz
            nx, ny, nz = normalize_or_fallback(nx, ny, nz, source[4], source[5], source[6])

            local ao = contact_ao_for_normal(
                contact_top, contact_bottom, contact_side, contact_overall,
                source[4], source[5], source[6]
            )

            if direct_floats then
                direct_floats[doff] = world_x
                direct_floats[doff + 1] = world_y
                direct_floats[doff + 2] = world_z
                direct_floats[doff + 3] = nx
                direct_floats[doff + 4] = ny
                direct_floats[doff + 5] = nz
                direct_floats[doff + 6] = cr
                direct_floats[doff + 7] = cg
                direct_floats[doff + 8] = cb
                direct_floats[doff + 9] = ca
                direct_floats[doff + 10] = reflectance
                direct_floats[doff + 11] = ao
                doff = doff + 12
            elseif _dyn_pool_active then
                local c = _static_vtx_cursor + 1
                _static_vtx_cursor = c
                local vt = _static_vtx_pool[c]
                if vt then
                    vt[1] = world_x; vt[2] = world_y; vt[3] = world_z
                    vt[4] = nx; vt[5] = ny; vt[6] = nz
                    vt[7] = cr; vt[8] = cg; vt[9] = cb; vt[10] = ca
                    vt[11] = reflectance; vt[12] = ao
                else
                    vt = { world_x, world_y, world_z, nx, ny, nz, cr, cg, cb, ca, reflectance, ao }
                    _static_vtx_pool[c] = vt
                end
                output[#output + 1] = vt
            else
                output[#output + 1] = {
                    world_x, world_y, world_z,
                    nx, ny, nz,
                    cr, cg, cb, ca,
                    reflectance,
                    ao,
                }
            end
        end
    end

    local upload_start = love.timer.getTime()
    local mesh
    if direct_bytedata then
        mesh = love.graphics.newMesh(renderer._static_vertex_format, total, "triangles", "static")
        mesh:setVertices(direct_bytedata)
        -- setVertices copies synchronously, releasing frees the C-heap payload now
        -- instead of whenever the (widened) load GC gets to the userdata
        direct_bytedata:release()
    else
        local packed = rbx_pack_vertices_bytedata(output, 12)
        if packed then
            mesh = love.graphics.newMesh(renderer._static_vertex_format, #output, "triangles", "static")
            mesh:setVertices(packed)
            packed:release()
        else
            mesh = love.graphics.newMesh(renderer._static_vertex_format, output, "triangles", "static")
        end
    end
    if renderer and renderer._add_load_stage_time then
        renderer:_add_load_stage_time("gpu_mesh_upload", love.timer.getTime() - upload_start)
        renderer:_note_load_cache_stat("gpu_mesh_upload_count")
        if renderer._note_gpu_upload_bytes then
            renderer:_note_gpu_upload_bytes(total * 12 * 4)
        end
    end
    -- publish only after the complete owned payload has uploaded successfully
    -- Weak keys do not retain retired Mesh objects. mutable writers retire proof
    -- before their fallible upload, unknown/legacy resources remain unproved
    local proofs = renderer._static_mesh_unit_alpha
    if not proofs then
        proofs = setmetatable({}, { __mode = "k" })
        renderer._static_mesh_unit_alpha = proofs
    end
    proofs[mesh] = vertex_alpha_is_one == true

    -- range staging: instance i owns verts [(i-1)*per+1, i*per]. only the static scene build
    -- passes instance_part_ids, dynamic re-bakes pass nothing and stage nothing
    if instance_part_ids and mesh then
        local per_instance = #local_vertices
        local stage = renderer._range_static_stage
        if not stage then
            stage = {}
            renderer._range_static_stage = stage
        end
        for i, pid in pairs(instance_part_ids) do
            stage[#stage + 1] = pid
            stage[#stage + 1] = mesh
            stage[#stage + 1] = (i - 1) * per_instance + 1
            stage[#stage + 1] = per_instance
        end
    end
    return mesh
end

function build_sky_face_vertices()
    local faces = {}

    local function make_face(v1, v2, v3, v4)
        local eps = 0.002
        local u_min, v_min = eps, eps
        local u_max, v_max = 1.0 - eps, 1.0 - eps
        return {
            { v1[1], v1[2], v1[3], u_min, v_min },
            { v2[1], v2[2], v2[3], u_max, v_min },
            { v3[1], v3[2], v3[3], u_max, v_max },
            { v1[1], v1[2], v1[3], u_min, v_min },
            { v3[1], v3[2], v3[3], u_max, v_max },
            { v4[1], v4[2], v4[3], u_min, v_max },
        }
    end

    local function rotate_face_uv_90(face_vertices)
        local rotated = {}
        for i = 1, #face_vertices do
            local vtx = face_vertices[i]
            local u = vtx[4]
            local v = vtx[5]
            rotated[i] = { vtx[1], vtx[2], vtx[3], 1.0 - v, u }
        end
        return rotated
    end

    local function rotate_face_uv_270(face_vertices)
        local rotated = {}
        for i = 1, #face_vertices do
            local vtx = face_vertices[i]
            local u = vtx[4]
            local v = vtx[5]
            rotated[i] = { vtx[1], vtx[2], vtx[3], v, u }
        end
        return rotated
    end

    local function flip_face_uv_vertical(face_vertices)
        local flipped = {}
        for i = 1, #face_vertices do
            local vtx = face_vertices[i]
            flipped[i] = { vtx[1], vtx[2], vtx[3], vtx[4], 1.0 - vtx[5] }
        end
        return flipped
    end

    local function flip_face_uv_horizontal(face_vertices)
        local flipped = {}
        for i = 1, #face_vertices do
            local vtx = face_vertices[i]
            flipped[i] = { vtx[1], vtx[2], vtx[3], 1.0 - vtx[4], vtx[5] }
        end
        return flipped
    end

    faces.SkyboxFt = flip_face_uv_vertical(make_face(
        { -0.5, -0.5, -0.5 },
        { 0.5, -0.5, -0.5 },
        { 0.5, 0.5, -0.5 },
        { -0.5, 0.5, -0.5 }
    ))
    faces.SkyboxBk = flip_face_uv_vertical(make_face(
        { 0.5, -0.5, 0.5 },
        { -0.5, -0.5, 0.5 },
        { -0.5, 0.5, 0.5 },
        { 0.5, 0.5, 0.5 }
    ))
    faces.SkyboxRt = flip_face_uv_vertical(make_face(
        { 0.5, -0.5, -0.5 },
        { 0.5, -0.5, 0.5 },
        { 0.5, 0.5, 0.5 },
        { 0.5, 0.5, -0.5 }
    ))
    faces.SkyboxLf = flip_face_uv_vertical(make_face(
        { -0.5, -0.5, 0.5 },
        { -0.5, -0.5, -0.5 },
        { -0.5, 0.5, -0.5 },
        { -0.5, 0.5, 0.5 }
    ))
    faces.SkyboxUp = rotate_face_uv_270(make_face(
        { -0.5, 0.5, -0.5 },
        { 0.5, 0.5, -0.5 },
        { 0.5, 0.5, 0.5 },
        { -0.5, 0.5, 0.5 }
    ))
    faces.SkyboxDn = rotate_face_uv_90(flip_face_uv_horizontal(make_face(
        { -0.5, -0.5, 0.5 },
        { 0.5, -0.5, 0.5 },
        { 0.5, -0.5, -0.5 },
        { -0.5, -0.5, -0.5 }
    )))

    return faces
end

local function build_fallback_textured_basis(nx, ny, nz)
    local axis_x, axis_y, axis_z = 0, 1, 0
    if math.abs(ny or 0) >= 0.999 then
        axis_x, axis_y, axis_z = 1, 0, 0
    end
    local tangent_x, tangent_y, tangent_z = cross(axis_x, axis_y, axis_z, nx, ny, nz)
    tangent_x, tangent_y, tangent_z = normalize_or_fallback(tangent_x, tangent_y, tangent_z, 1, 0, 0)
    local bitangent_x, bitangent_y, bitangent_z = cross(nx, ny, nz, tangent_x, tangent_y, tangent_z)
    bitangent_x, bitangent_y, bitangent_z = normalize_or_fallback(bitangent_x, bitangent_y, bitangent_z, 0, 0, 1)
    return tangent_x, tangent_y, tangent_z, bitangent_x, bitangent_y, bitangent_z
end

local function orthonormalize_textured_basis(nx, ny, nz, tx, ty, tz, bx, by, bz)
    local tangent_dot = dot(tx, ty, tz, nx, ny, nz)
    tx = tx - nx * tangent_dot
    ty = ty - ny * tangent_dot
    tz = tz - nz * tangent_dot

    local tangent_len_sq = tx * tx + ty * ty + tz * tz
    if tangent_len_sq <= 1e-8 then
        return build_fallback_textured_basis(nx, ny, nz)
    end

    local tangent_scale = 1 / math.sqrt(tangent_len_sq)
    tx = tx * tangent_scale
    ty = ty * tangent_scale
    tz = tz * tangent_scale

    local bitangent_normal_dot = dot(bx, by, bz, nx, ny, nz)
    local bitangent_tangent_dot = dot(bx, by, bz, tx, ty, tz)
    bx = bx - nx * bitangent_normal_dot - tx * bitangent_tangent_dot
    by = by - ny * bitangent_normal_dot - ty * bitangent_tangent_dot
    bz = bz - nz * bitangent_normal_dot - tz * bitangent_tangent_dot

    local bitangent_len_sq = bx * bx + by * by + bz * bz
    if bitangent_len_sq <= 1e-8 then
        bx, by, bz = cross(nx, ny, nz, tx, ty, tz)
        bitangent_len_sq = bx * bx + by * by + bz * bz
        if bitangent_len_sq <= 1e-8 then
            return build_fallback_textured_basis(nx, ny, nz)
        end
    end

    local bitangent_scale = 1 / math.sqrt(bitangent_len_sq)
    bx = bx * bitangent_scale
    by = by * bitangent_scale
    bz = bz * bitangent_scale

    local handedness_x, handedness_y, handedness_z = cross(tx, ty, tz, bx, by, bz)
    if dot(handedness_x, handedness_y, handedness_z, nx, ny, nz) < 0 then
        bx = -bx
        by = -by
        bz = -bz
    end

    return tx, ty, tz, bx, by, bz
end

local function compute_textured_tangent_basis(
    w1x, w1y, w1z, u1, v1,
    w2x, w2y, w2z, u2, v2,
    w3x, w3y, w3z, u3, v3,
    nnx, nny, nnz
)
    local edge1_x = w2x - w1x
    local edge1_y = w2y - w1y
    local edge1_z = w2z - w1z
    local edge2_x = w3x - w1x
    local edge2_y = w3y - w1y
    local edge2_z = w3z - w1z
    local delta_u1 = u2 - u1
    local delta_v1 = v2 - v1
    local delta_u2 = u3 - u1
    local delta_v2 = v3 - v1
    local determinant = delta_u1 * delta_v2 - delta_u2 * delta_v1

    if math.abs(determinant) <= 1e-8 then
        -- Degenerate UVs still belong to a geometric triangle. Derive their
        -- fallback from its edges so a rigid pose update and a fresh bake
        -- produce the same basis, a world-up fallback changes under rotation
        local projection=dot(edge1_x,edge1_y,edge1_z,nnx,nny,nnz)
        local tx,ty,tz=edge1_x-nnx*projection,edge1_y-nny*projection,edge1_z-nnz*projection
        local length=tx*tx+ty*ty+tz*tz
        if length<=1e-20 then
            projection=dot(edge2_x,edge2_y,edge2_z,nnx,nny,nnz)
            tx,ty,tz=edge2_x-nnx*projection,edge2_y-nny*projection,edge2_z-nnz*projection
            length=tx*tx+ty*ty+tz*tz
        end
        if length<=1e-20 then return build_fallback_textured_basis(nnx,nny,nnz)end
        local inverse=1/math.sqrt(length);tx,ty,tz=tx*inverse,ty*inverse,tz*inverse
        local bx,by,bz=cross(nnx,nny,nnz,tx,ty,tz)
        return tx,ty,tz,bx,by,bz
    end

    local inverse = 1 / determinant
    local tangent_x = (edge1_x * delta_v2 - edge2_x * delta_v1) * inverse
    local tangent_y = (edge1_y * delta_v2 - edge2_y * delta_v1) * inverse
    local tangent_z = (edge1_z * delta_v2 - edge2_z * delta_v1) * inverse
    local bitangent_x = (edge2_x * delta_u1 - edge1_x * delta_u2) * inverse
    local bitangent_y = (edge2_y * delta_u1 - edge1_y * delta_u2) * inverse
    local bitangent_z = (edge2_z * delta_u1 - edge1_z * delta_u2) * inverse

    return orthonormalize_textured_basis(
        nnx, nny, nnz,
        tangent_x, tangent_y, tangent_z,
        bitangent_x, bitangent_y, bitangent_z
    )
end
RBX._compute_textured_tangent_basis = compute_textured_tangent_basis

function push_textured_vertex(vertices, x, y, z, nx, ny, nz, u, v, r, g, b, a, reflectance,
                              tangent_x, tangent_y, tangent_z, bitangent_x, bitangent_y, bitangent_z, contact_ao)
    tangent_x = tangent_x or 0
    tangent_y = tangent_y or 0
    tangent_z = tangent_z or 0
    bitangent_x = bitangent_x or 0
    bitangent_y = bitangent_y or 0
    bitangent_z = bitangent_z or 0
    contact_ao = clamp(tonumber(contact_ao) or 0, 0, 1)
    reflectance = clamp(reflectance or 0, 0, 1)
    if _dyn_pool_active then
        local c = _textured_vtx_cursor + 1
        _textured_vtx_cursor = c
        local vt = _textured_vtx_pool[c]
        if vt then
            vt[1] = x; vt[2] = y; vt[3] = z
            vt[4] = nx; vt[5] = ny; vt[6] = nz
            vt[7] = u; vt[8] = v
            vt[9] = r; vt[10] = g; vt[11] = b; vt[12] = a
            vt[13] = reflectance
            vt[14] = tangent_x; vt[15] = tangent_y; vt[16] = tangent_z
            vt[17] = bitangent_x; vt[18] = bitangent_y; vt[19] = bitangent_z
            vt[20] = contact_ao
        else
            vt = {
                x, y, z, nx, ny, nz, u, v, r, g, b, a, reflectance,
                tangent_x, tangent_y, tangent_z, bitangent_x, bitangent_y, bitangent_z, contact_ao,
            }
            _textured_vtx_pool[c] = vt
        end
        vertices[#vertices + 1] = vt
    else
        local buf = vertices.vbuf
        if buf ~= nil then
            local n = vertices.vbuf_n
            if n + 20 > vertices.vbuf_cap then
                buf = grow_flat_vertex_list(vertices, n + 20)
            end
            buf[n] = x; buf[n + 1] = y; buf[n + 2] = z
            buf[n + 3] = nx; buf[n + 4] = ny; buf[n + 5] = nz
            buf[n + 6] = u; buf[n + 7] = v
            buf[n + 8] = r; buf[n + 9] = g; buf[n + 10] = b; buf[n + 11] = a
            buf[n + 12] = reflectance
            buf[n + 13] = tangent_x; buf[n + 14] = tangent_y; buf[n + 15] = tangent_z
            buf[n + 16] = bitangent_x; buf[n + 17] = bitangent_y; buf[n + 18] = bitangent_z
            buf[n + 19] = contact_ao
            vertices.vbuf_n = n + 20
        else
            vertices[#vertices + 1] = {
                x, y, z,
                nx, ny, nz,
                u, v,
                r, g, b, a,
                reflectance,
                tangent_x, tangent_y, tangent_z,
                bitangent_x, bitangent_y, bitangent_z,
                contact_ao,
            }
        end
    end
end

-- reused corner scratch for the flat quad fast path below (single-threaded, no yields inside)
local _quad_sx = { 0, 0, 0, 0 }
local _quad_sy = { 0, 0, 0, 0 }
local _quad_sz = { 0, 0, 0, 0 }
local _quad_su = { 0, 0, 0, 0 }
local _quad_sv = { 0, 0, 0, 0 }
local _quad_order_aligned = { 1, 2, 3, 1, 3, 4 }
local _quad_order_flipped = { 1, 3, 2, 1, 4, 3 }

function push_textured_quad_oriented(vertices,
                                           w1x, w1y, w1z, u1, v1,
                                           w2x, w2y, w2z, u2, v2,
                                           w3x, w3y, w3z, u3, v3,
                                           w4x, w4y, w4z, u4, v4,
                                           nnx, nny, nnz,
                                           r, g, b, a, reflectance)
    local tangent_x, tangent_y, tangent_z,
    bitangent_x, bitangent_y, bitangent_z = compute_textured_tangent_basis(
        w1x, w1y, w1z, u1, v1,
        w2x, w2y, w2z, u2, v2,
        w3x, w3y, w3z, u3, v3,
        nnx, nny, nnz
    )
    local ax = w2x - w1x
    local ay = w2y - w1y
    local az = w2z - w1z
    local bx = w3x - w1x
    local by = w3y - w1y
    local bz = w3z - w1z
    local cx, cy, cz = cross(ax, ay, az, bx, by, bz)
    local aligned = dot(cx, cy, cz, nnx, nny, nnz) >= 0

    -- flat fast path: inlining six push_textured_vertex calls (guards + 20 stores each) into a
    -- hosting trace blew the register allocator (NYI-coalescing / spill-slot aborts) and left
    -- decal appends interpreted, this small store loop keeps almost nothing live and compiles
    -- store order byte-matches the push chain below (contact_ao defaults to 0 there)
    local buf = (not _dyn_pool_active) and vertices.vbuf or nil
    if buf ~= nil then
        local n = vertices.vbuf_n
        if n + 120 > vertices.vbuf_cap then
            buf = grow_flat_vertex_list(vertices, n + 120)
        end
        local refl = clamp(reflectance or 0, 0, 1)
        _quad_sx[1], _quad_sy[1], _quad_sz[1], _quad_su[1], _quad_sv[1] = w1x, w1y, w1z, u1, v1
        _quad_sx[2], _quad_sy[2], _quad_sz[2], _quad_su[2], _quad_sv[2] = w2x, w2y, w2z, u2, v2
        _quad_sx[3], _quad_sy[3], _quad_sz[3], _quad_su[3], _quad_sv[3] = w3x, w3y, w3z, u3, v3
        _quad_sx[4], _quad_sy[4], _quad_sz[4], _quad_su[4], _quad_sv[4] = w4x, w4y, w4z, u4, v4
        local order = aligned and _quad_order_aligned or _quad_order_flipped
        for k = 1, 6 do
            local j = order[k]
            local base = n + (k - 1) * 20
            buf[base] = _quad_sx[j]
            buf[base + 1] = _quad_sy[j]
            buf[base + 2] = _quad_sz[j]
            buf[base + 3] = nnx
            buf[base + 4] = nny
            buf[base + 5] = nnz
            buf[base + 6] = _quad_su[j]
            buf[base + 7] = _quad_sv[j]
            buf[base + 8] = r
            buf[base + 9] = g
            buf[base + 10] = b
            buf[base + 11] = a
            buf[base + 12] = refl
            buf[base + 13] = tangent_x
            buf[base + 14] = tangent_y
            buf[base + 15] = tangent_z
            buf[base + 16] = bitangent_x
            buf[base + 17] = bitangent_y
            buf[base + 18] = bitangent_z
            buf[base + 19] = 0
        end
        vertices.vbuf_n = n + 120
        return
    end

    if aligned then
        push_textured_vertex(vertices, w1x, w1y, w1z, nnx, nny, nnz, u1, v1, r, g, b, a, reflectance,
            tangent_x, tangent_y, tangent_z, bitangent_x, bitangent_y, bitangent_z)
        push_textured_vertex(vertices, w2x, w2y, w2z, nnx, nny, nnz, u2, v2, r, g, b, a, reflectance,
            tangent_x, tangent_y, tangent_z, bitangent_x, bitangent_y, bitangent_z)
        push_textured_vertex(vertices, w3x, w3y, w3z, nnx, nny, nnz, u3, v3, r, g, b, a, reflectance,
            tangent_x, tangent_y, tangent_z, bitangent_x, bitangent_y, bitangent_z)
        push_textured_vertex(vertices, w1x, w1y, w1z, nnx, nny, nnz, u1, v1, r, g, b, a, reflectance,
            tangent_x, tangent_y, tangent_z, bitangent_x, bitangent_y, bitangent_z)
        push_textured_vertex(vertices, w3x, w3y, w3z, nnx, nny, nnz, u3, v3, r, g, b, a, reflectance,
            tangent_x, tangent_y, tangent_z, bitangent_x, bitangent_y, bitangent_z)
        push_textured_vertex(vertices, w4x, w4y, w4z, nnx, nny, nnz, u4, v4, r, g, b, a, reflectance,
            tangent_x, tangent_y, tangent_z, bitangent_x, bitangent_y, bitangent_z)
    else
        push_textured_vertex(vertices, w1x, w1y, w1z, nnx, nny, nnz, u1, v1, r, g, b, a, reflectance,
            tangent_x, tangent_y, tangent_z, bitangent_x, bitangent_y, bitangent_z)
        push_textured_vertex(vertices, w3x, w3y, w3z, nnx, nny, nnz, u3, v3, r, g, b, a, reflectance,
            tangent_x, tangent_y, tangent_z, bitangent_x, bitangent_y, bitangent_z)
        push_textured_vertex(vertices, w2x, w2y, w2z, nnx, nny, nnz, u2, v2, r, g, b, a, reflectance,
            tangent_x, tangent_y, tangent_z, bitangent_x, bitangent_y, bitangent_z)
        push_textured_vertex(vertices, w1x, w1y, w1z, nnx, nny, nnz, u1, v1, r, g, b, a, reflectance,
            tangent_x, tangent_y, tangent_z, bitangent_x, bitangent_y, bitangent_z)
        push_textured_vertex(vertices, w4x, w4y, w4z, nnx, nny, nnz, u4, v4, r, g, b, a, reflectance,
            tangent_x, tangent_y, tangent_z, bitangent_x, bitangent_y, bitangent_z)
        push_textured_vertex(vertices, w3x, w3y, w3z, nnx, nny, nnz, u3, v3, r, g, b, a, reflectance,
            tangent_x, tangent_y, tangent_z, bitangent_x, bitangent_y, bitangent_z)
    end
end

function push_textured_triangle_oriented(vertices,
                                               w1x, w1y, w1z, n1x, n1y, n1z, u1, v1,
                                               w2x, w2y, w2z, n2x, n2y, n2z, u2, v2,
                                               w3x, w3y, w3z, n3x, n3y, n3z, u3, v3,
                                               nnx, nny, nnz,
                                               r, g, b, a, reflectance)
    local tangent_x, tangent_y, tangent_z,
    bitangent_x, bitangent_y, bitangent_z = compute_textured_tangent_basis(
        w1x, w1y, w1z, u1, v1,
        w2x, w2y, w2z, u2, v2,
        w3x, w3y, w3z, u3, v3,
        nnx, nny, nnz
    )
    local ax = w2x - w1x
    local ay = w2y - w1y
    local az = w2z - w1z
    local bx = w3x - w1x
    local by = w3y - w1y
    local bz = w3z - w1z
    local cx, cy, cz = cross(ax, ay, az, bx, by, bz)
    local aligned = dot(cx, cy, cz, nnx, nny, nnz) >= 0

    if aligned then
        push_textured_vertex(vertices, w1x, w1y, w1z, n1x, n1y, n1z, u1, v1, r, g, b, a, reflectance,
            tangent_x, tangent_y, tangent_z, bitangent_x, bitangent_y, bitangent_z)
        push_textured_vertex(vertices, w2x, w2y, w2z, n2x, n2y, n2z, u2, v2, r, g, b, a, reflectance,
            tangent_x, tangent_y, tangent_z, bitangent_x, bitangent_y, bitangent_z)
        push_textured_vertex(vertices, w3x, w3y, w3z, n3x, n3y, n3z, u3, v3, r, g, b, a, reflectance,
            tangent_x, tangent_y, tangent_z, bitangent_x, bitangent_y, bitangent_z)
    else
        push_textured_vertex(vertices, w1x, w1y, w1z, n1x, n1y, n1z, u1, v1, r, g, b, a, reflectance,
            tangent_x, tangent_y, tangent_z, bitangent_x, bitangent_y, bitangent_z)
        push_textured_vertex(vertices, w3x, w3y, w3z, n3x, n3y, n3z, u3, v3, r, g, b, a, reflectance,
            tangent_x, tangent_y, tangent_z, bitangent_x, bitangent_y, bitangent_z)
        push_textured_vertex(vertices, w2x, w2y, w2z, n2x, n2y, n2z, u2, v2, r, g, b, a, reflectance,
            tangent_x, tangent_y, tangent_z, bitangent_x, bitangent_y, bitangent_z)
    end
end

function transform_local_point(px, py, pz, rx, ry, rz, ux, uy, uz, bx, by, bz, lx, ly, lz)
    return px + rx * lx + ux * ly + bx * lz,
        py + ry * lx + uy * ly + by * lz,
        pz + rz * lx + uz * ly + bz * lz
end

function transform_local_normal(rx, ry, rz, ux, uy, uz, bx, by, bz, nx, ny, nz)
    local out_x = rx * nx + ux * ny + bx * nz
    local out_y = ry * nx + uy * ny + by * nz
    local out_z = rz * nx + uz * ny + bz * nz
    return normalize_or_fallback(out_x, out_y, out_z, nx, ny, nz)
end

function RBX:_fetch_remote_mesh_asset_bytes(asset_reference)
    -- Legacy mesh acquisition is synchronous.  keep it behind a distinct,
    -- explicit gate so enabling the non-blocking texture pipeline can never
    -- introduce a 20-second-per-mesh classify stall
    if self.allow_remote_mesh_fetch ~= true then
        return nil
    end

    local asset_id = extract_asset_id(asset_reference)
    if not asset_id then
        return nil
    end

    local cached = self._remote_mesh_asset_cache[asset_id]
    if cached ~= nil then
        return cached or nil
    end

    local url = "https://assetdelivery.roblox.com/v1/asset/?id=" .. asset_id
    local body = nil

    if not body and io and type(io.popen) == "function" then
        local quoted_url = "'" .. url:gsub("'", "'\\''") .. "'"
        local handle = io.popen(
            "curl -L --compressed --fail --silent --show-error --connect-timeout 4 --max-time 20 " .. quoted_url,
            "r"
        )
        if handle then
            local fetched = handle:read("*a")
            local ok, _, code = handle:close()
            if (ok == true or code == 0) and type(fetched) == "string" and fetched ~= "" then
                body = fetched
            end
        end
    end

    self._remote_mesh_asset_cache[asset_id] = body or false
    return body
end

function RBX:_get_local_mesh_cache_controller()
    self._mesh_cache = self._mesh_cache or {}
    local controller = self._local_mesh_cache_controller
    if controller and controller:is_bound_to(self._mesh_cache) then
        return controller
    end

    local configured_bytes = tonumber(self.local_mesh_cache_max_bytes)
    if configured_bytes == nil then
        local configured_megabytes = tonumber(self.local_mesh_cache_max_megabytes)
        if configured_megabytes ~= nil then
            configured_bytes = configured_megabytes * 1024 * 1024
        end
    end
    controller = LocalMeshCache.new(self._mesh_cache, {
        max_bytes = configured_bytes,
        max_entries = tonumber(self.local_mesh_cache_max_entries),
        negative_ttl_seconds = tonumber(self.local_mesh_cache_negative_ttl_seconds),
        now = self.local_mesh_cache_clock,
    })
    self._local_mesh_cache_controller = controller
    return controller
end

---Reconfigure the decoded local-mesh budget without rebuilding scene GPU data
---existing entries are evicted from oldest to newest until both ceilings hold
---Recognized options: max_bytes/max_megabytes, max_entries,
---negative_ttl_seconds, and an optional `clock` callback
function RBX:configure_local_mesh_cache(options)
    options = options or {}
    if options.max_bytes ~= nil then
        self.local_mesh_cache_max_bytes = options.max_bytes
    elseif options.max_megabytes ~= nil then
        self.local_mesh_cache_max_bytes =
            (tonumber(options.max_megabytes) or 0) * 1024 * 1024
    end
    if options.max_entries ~= nil then
        self.local_mesh_cache_max_entries = options.max_entries
    end
    if options.negative_ttl_seconds ~= nil then
        self.local_mesh_cache_negative_ttl_seconds =
            options.negative_ttl_seconds
    end
    if type(options.clock) == "function" then
        self.local_mesh_cache_clock = options.clock
    end

    local controller = self:_get_local_mesh_cache_controller()
    controller:reconfigure({
        max_bytes = self.local_mesh_cache_max_bytes,
        max_entries = self.local_mesh_cache_max_entries,
        negative_ttl_seconds =
            self.local_mesh_cache_negative_ttl_seconds,
        now = self.local_mesh_cache_clock,
    })
    return controller:snapshot()
end

function RBX:get_local_mesh_cache_stats()
    return self:_get_local_mesh_cache_controller():snapshot()
end

RBX._estimate_local_mesh_cache_bytes =
    LocalMeshCache.estimate_decoded_bytes

local function note_canonical_asset_seen(renderer, cache_key)
    renderer._canonical_asset_seen = renderer._canonical_asset_seen or {}
    if renderer._canonical_asset_seen[cache_key] then
        renderer:_note_load_cache_stat("duplicate_asset_count")
    else
        renderer._canonical_asset_seen[cache_key] = true
    end
end

local function current_map_asset_directory(renderer)
    return RBX._asset_paths.map_directory(renderer._map_build_path
        or renderer.map_path or RBX._last_parsed_map_path)
end

---both local paths and Roblox IDs resolve inside the current place's asset
---directory. full filenames matter: A.rbxl and A.rbxlx own independent copies
function RBX:_renderer_asset_cache_key(value, asset_type)
    local context = current_map_asset_directory(self)
        .. "\0root:" .. tostring(self.asset_root or "")
    local memo = self._renderer_asset_cache_key_memo
    local by_type = type(memo) == "table" and memo[asset_type] or nil
    local cached = type(by_type) == "table" and by_type[value] or nil
    if cached and cached.context == context then return cached.key end
    local result = RBX._canonical_asset_cache_key(value, asset_type)
        .. "\0map-assets:" .. context
    if type(value) == "string" then
        memo = memo or {}
        self._renderer_asset_cache_key_memo = memo
        by_type = by_type or {}
        memo[asset_type] = by_type
        by_type[value] = { context = context, key = result }
    end
    return result
end

---CSG ChildData composition can recursively resolve plain local MeshIds and is
---also transformed by the renderer's loaded-map mirror policy. this token lets
---the content cache retain deterministic results for a same-context reload
---without sharing them into another place's asset copies or coordinate mode
function RBX:_embedded_mesh_decode_context_key()
    local folders = self.asset_folders or {}
    return table.concat({
        current_map_asset_directory(self),
        tostring(self.asset_root or ""),
        tostring(folders.asset or ""),
        self.flip_loaded_map_horizontally == false and "mirror-x:0" or "mirror-x:1",
    }, "\0")
end

function RBX:_get_or_parse_local_mesh(mesh_path, asset_type)
    if type(mesh_path) ~= "string" or trim(mesh_path) == "" then
        return nil
    end

    asset_type = asset_type or "mesh"
    local is_union = asset_type == "csg_mesh"
    local cache_key = self:_renderer_asset_cache_key(mesh_path, asset_type)
    note_canonical_asset_seen(self, cache_key)
    local cache = self:_get_local_mesh_cache_controller()
    -- Positive decoded values have no expiry. probe the compatibility values
    -- table first so a hit can touch the weighted LRU without repeating path
    -- resolution. missing and finite-negative keys retain the old resolve-first
    -- ordering, including its cache-miss/TTL diagnostic semantics
    local direct_cached = self._mesh_cache and self._mesh_cache[cache_key]
    if direct_cached ~= nil and direct_cached ~= false then
        local cached, cache_hit = cache:get(cache_key)
        if cache_hit then
            self:_note_load_cache_stat(is_union and "union_cache_hits" or "mesh_cache_hits")
            self.reused_mesh_count = (self.reused_mesh_count or 0) + 1
            return cached
        end
    end

    local resolved = self:_resolve_asset_path(
        mesh_path, asset_type, cache_key, true)
    if not resolved then
        return nil
    end

    local cached, cache_hit = cache:get(cache_key)
    if cache_hit then
        self:_note_load_cache_stat(is_union and "union_cache_hits" or "mesh_cache_hits")
        if cached then
            self.reused_mesh_count = (self.reused_mesh_count or 0) + 1
        end
        return cached or nil
    end
    self:_note_load_cache_stat(is_union and "union_cache_misses" or "mesh_cache_misses")

    -- mark the key before file I/O: a sliced/re-entrant host may continue cache
    -- maintenance while this decoder is suspended, but can never evict the key
    -- whose replacement is being parsed and published
    local owns_publish = cache:begin_publish(cache_key)
    local function read_and_decode()
        local read_start = love.timer.getTime()
        local data = love.filesystem.read(resolved)
        self:_add_load_stage_time("mesh_asset_file_read", love.timer.getTime() - read_start)
        local parsed = nil
        if data then
            local decode_start = love.timer.getTime()
            parsed = parse_renderable_mesh_data(data)
            if asset_type == "csg_mesh"
                and RBX._get_renderable_mesh_score(parsed) < 4 then
                parsed = RBX._choose_preferred_renderable_mesh(
                    parsed,
                    self:_extract_csg_childdata_mesh_from_asset(data)
                )
            end
            self:_add_load_stage_time(is_union and "union_csg_decode" or "mesh_decode",
                love.timer.getTime() - decode_start)
            local validation_start = love.timer.getTime()
            if parsed then
                local has_normals = type(parsed.normals) == "table" and #parsed.normals > 0
                local has_uvs = type(parsed.uvs) == "table" and #parsed.uvs > 0
                if not has_normals or not has_uvs then
                    self:_note_load_cache_stat(
                        has_normals and "mesh_uv_missing_assets"
                            or "mesh_normal_missing_assets")
                end
            end
            self:_add_load_stage_time("mesh_normal_uv_validation",
                love.timer.getTime() - validation_start)
        end
        return parsed
    end

    local traceback = debug and debug.traceback or tostring
    local decoded_ok, parsed_or_error = xpcall(read_and_decode, traceback)
    if not decoded_ok then
        if owns_publish then cache:finish_publish(cache_key) end
        error(parsed_or_error, 0)
    end
    local parsed = parsed_or_error

    if owns_publish then
        local publish_ok, publish_error = pcall(
            cache.publish, cache, cache_key, parsed or false)
        cache:finish_publish(cache_key)
        if not publish_ok then error(publish_error, 0) end
    end
    if parsed then
        self.unique_mesh_count = (self.unique_mesh_count or 0) + 1
    end
    return parsed or nil
end

function RBX:_build_mesh_from_parsed_csg_child_parts(parsed_parts)
    if type(parsed_parts) ~= "table" or #parsed_parts == 0 then
        return nil
    end

    local positions, normals, uvs = {}, {}, {}
    local min_x, min_y, min_z = math.huge, math.huge, math.huge
    local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

    local function append_bounds(x, y, z)
        min_x = math.min(min_x, x)
        min_y = math.min(min_y, y)
        min_z = math.min(min_z, z)
        max_x = math.max(max_x, x)
        max_y = math.max(max_y, y)
        max_z = math.max(max_z, z)
    end

    local function append_transformed_mesh(mesh_data, transform)
        if type(mesh_data) ~= "table" or type(transform) ~= "table" then
            return false
        end

        local mesh_positions = mesh_data.positions or {}
        local mesh_normals = mesh_data.normals or {}
        local mesh_uvs = mesh_data.uvs or {}
        local vertex_count = math.floor(#mesh_positions / 3)
        if vertex_count <= 0 then
            return false
        end

        for vertex_index = 1, vertex_count do
            local pidx = (vertex_index - 1) * 3 + 1
            local uidx = (vertex_index - 1) * 2 + 1

            local world_x, world_y, world_z = transform_local_point(
                transform.px, transform.py, transform.pz,
                transform.rx, transform.ry, transform.rz,
                transform.ux, transform.uy, transform.uz,
                transform.bx, transform.by, transform.bz,
                (mesh_positions[pidx] or 0) * transform.scale_x,
                (mesh_positions[pidx + 1] or 0) * transform.scale_y,
                (mesh_positions[pidx + 2] or 0) * transform.scale_z
            )

            local world_nx, world_ny, world_nz = transform_local_normal(
                transform.rx, transform.ry, transform.rz,
                transform.ux, transform.uy, transform.uz,
                transform.bx, transform.by, transform.bz,
                mesh_normals[pidx] or 0,
                mesh_normals[pidx + 1] or 1,
                mesh_normals[pidx + 2] or 0
            )

            positions[#positions + 1] = world_x
            positions[#positions + 1] = world_y
            positions[#positions + 1] = world_z

            normals[#normals + 1] = world_nx
            normals[#normals + 1] = world_ny
            normals[#normals + 1] = world_nz

            uvs[#uvs + 1] = mesh_uvs[uidx] or 0
            uvs[#uvs + 1] = mesh_uvs[uidx + 1] or 0

            append_bounds(world_x, world_y, world_z)
        end

        return true
    end

    for i = 1, #parsed_parts do
        local runtime_part = runtime_part_from_parsed(parsed_parts[i], -i)
        self:_apply_loaded_runtime_part_coordinate_fix(runtime_part)

        local part_mesh = nil
        local appended_mesh = false
        if runtime_part.MeshId or part_has_embedded_mesh_payload(runtime_part) then
            part_mesh = self:_get_or_parse_part_mesh(runtime_part)
        end

        if part_mesh then
            local transform = self:_get_mesh_render_transform(runtime_part, part_mesh)
            appended_mesh = append_transformed_mesh(part_mesh, transform)
        end

        -- ChildData composition creates negative-id probe parts that never enter
        -- renderer.parts. a normal part releases its content-cache pin during
        -- Destroy/map reset, these short-lived probes have no such lifecycle
        -- the composed arrays above own everything needed after this point, so
        -- retire the probe binding immediately instead of poisoning generation
        -- retirement with an unreachable live pin
        if self._release_part_embedded_mesh_cache then
            self:_release_part_embedded_mesh_cache(runtime_part)
        end

        if not appended_mesh then
            local render_geometry_key = get_runtime_part_render_geometry_key(runtime_part)
            local primitive = self._primitive_vertices and self._primitive_vertices[render_geometry_key]
            if primitive then
                local px, py, pz,
                rx, ry, rz,
                ux, uy, uz,
                bx, by, bz,
                sx, sy, sz = get_runtime_part_render_basis(runtime_part)

                for vertex_index = 1, #primitive, 3 do
                    local va = primitive[vertex_index]
                    local vb = primitive[vertex_index + 1]
                    local vc = primitive[vertex_index + 2]
                    if va and vb and vc then
                        local ax, ay, az = transform_local_point(
                            px, py, pz,
                            rx, ry, rz,
                            ux, uy, uz,
                            bx, by, bz,
                            (va[1] or 0) * sx,
                            (va[2] or 0) * sy,
                            (va[3] or 0) * sz
                        )
                        local bxw, byw, bzw = transform_local_point(
                            px, py, pz,
                            rx, ry, rz,
                            ux, uy, uz,
                            bx, by, bz,
                            (vb[1] or 0) * sx,
                            (vb[2] or 0) * sy,
                            (vb[3] or 0) * sz
                        )
                        local cx, cy, cz = transform_local_point(
                            px, py, pz,
                            rx, ry, rz,
                            ux, uy, uz,
                            bx, by, bz,
                            (vc[1] or 0) * sx,
                            (vc[2] or 0) * sy,
                            (vc[3] or 0) * sz
                        )

                        local nx, ny, nz = cross(
                            bxw - ax, byw - ay, bzw - az,
                            cx - ax, cy - ay, cz - az
                        )
                        nx, ny, nz = normalize_or_fallback(nx, ny, nz, 0, 1, 0)

                        positions[#positions + 1] = ax
                        positions[#positions + 1] = ay
                        positions[#positions + 1] = az
                        positions[#positions + 1] = bxw
                        positions[#positions + 1] = byw
                        positions[#positions + 1] = bzw
                        positions[#positions + 1] = cx
                        positions[#positions + 1] = cy
                        positions[#positions + 1] = cz

                        for _ = 1, 3 do
                            normals[#normals + 1] = nx
                            normals[#normals + 1] = ny
                            normals[#normals + 1] = nz
                            uvs[#uvs + 1] = 0
                            uvs[#uvs + 1] = 0
                        end

                        append_bounds(ax, ay, az)
                        append_bounds(bxw, byw, bzw)
                        append_bounds(cx, cy, cz)
                    end
                end
            end
        end
    end

    if #positions == 0 then
        return nil
    end

    return {
        positions = positions,
        normals = normals,
        uvs = uvs,
        bounds = {
            min_x = min_x,
            min_y = min_y,
            min_z = min_z,
            max_x = max_x,
            max_y = max_y,
            max_z = max_z,
        },
        source_kind = "csg_child_parts",
    }
end

function RBX:_extract_csg_childdata_mesh_from_asset(data)
    if type(data) ~= "string" or data == "" then
        return nil
    end

    local decoded_data = maybe_decompress_gzip_data(data) or data
    local function build_from_parts(parts)
        return self:_build_mesh_from_parsed_csg_child_parts(parts)
    end

    local function build_from_nested_data(candidate)
        if type(candidate) ~= "string" or candidate == "" then
            return nil
        end

        local nested_data = maybe_decompress_gzip_data(candidate) or candidate
        if starts_with(nested_data, RBX.BINARY_SIGNATURE) then
            local nested_roots = decode_rbxl_binary(nested_data)
            if nested_roots then
                local nested_parts = collect_supported_parts_from_tree(nested_roots)
                local mesh = build_from_parts(nested_parts)
                if mesh then
                    return mesh
                end
            end
        elseif looks_like_roblox_xml(nested_data) then
            local nested_parts = parse_supported_parts(nested_data)
            local mesh = build_from_parts(nested_parts)
            if mesh then
                return mesh
            end
        end

        return nil
    end

    if starts_with(decoded_data, RBX.BINARY_SIGNATURE) then
        local roots = decode_rbxl_binary(decoded_data)
        if not roots then
            return nil
        end

        local direct = build_from_parts(collect_supported_parts_from_tree(roots))
        if direct then
            return direct
        end

        return walk_instance_tree(roots, function(instance)
            return build_from_nested_data(instance.ChildData) or build_from_nested_data(instance.ChildData2)
        end)
    end

    if looks_like_roblox_xml(decoded_data) then
        local direct = build_from_parts(parse_supported_parts(decoded_data))
        if direct then
            return direct
        end
    end

    return nil
end

function RBX:_resolve_asset_path(
        asset_path, asset_type, precomputed_cache_key, canonical_seen)
    asset_type = asset_type or "texture"
    local normalize_start = love.timer.getTime()
    asset_path = normalize_asset_path(asset_path)
    if asset_path == "" then
        return nil
    end

    local cache_key = precomputed_cache_key
        or self:_renderer_asset_cache_key(asset_path, asset_type)
    self:_add_load_stage_time("asset_id_normalization", love.timer.getTime() - normalize_start)
    if canonical_seen ~= true then
        note_canonical_asset_seen(self, cache_key)
    end

    local resolve_start = love.timer.getTime()
    local cached = self._asset_path_cache[cache_key]
    if cached ~= nil then
        local stage_name = (asset_type == "mesh" or asset_type == "csg_mesh")
            and "mesh_asset_resolve"
            or "texture_asset_resolve"
        self:_add_load_stage_time(stage_name, love.timer.getTime() - resolve_start)
        return cached or nil
    end

    local candidates = RBX._asset_paths.candidates(asset_path, asset_type, {
        asset_id = extract_asset_id(asset_path),
        map_path = self._map_build_path or self.map_path or RBX._last_parsed_map_path,
        asset_root = self.asset_root,
        asset_folders = self.asset_folders,
    })

    for i = 1, #candidates do
        if file_exists(candidates[i]) then
            self._asset_path_cache[cache_key] = candidates[i]
            local stage_name = (asset_type == "mesh" or asset_type == "csg_mesh")
                and "mesh_asset_resolve"
                or "texture_asset_resolve"
            self:_add_load_stage_time(stage_name, love.timer.getTime() - resolve_start)
            return candidates[i]
        end
    end

    self._asset_path_cache[cache_key] = false
    local stage_name = (asset_type == "mesh" or asset_type == "csg_mesh")
        and "mesh_asset_resolve"
        or "texture_asset_resolve"
    self:_add_load_stage_time(stage_name, love.timer.getTime() - resolve_start)
    return nil
end

function RBX._bleed_image_data_alpha(image_data)
    return RBX._alpha_bleed.bleed(image_data)
end

-- 16x16 magenta/black checker for gui image misses: a visibly-wrong texture beats an
-- invisible one when authoring guis
function RBX:_get_gui_placeholder_texture()
    if self._gui_placeholder_texture then
        return self._gui_placeholder_texture
    end
    local data = love.image.newImageData(16, 16)
    for y = 0, 15 do
        for x = 0, 15 do
            if (math.floor(x / 4) + math.floor(y / 4)) % 2 == 0 then
                data:setPixel(x, y, 1, 0, 1, 1)
            else
                data:setPixel(x, y, 0, 0, 0, 1)
            end
        end
    end
    local texture = love.graphics.newImage(data)
    texture:setFilter("nearest", "nearest")
    texture:setWrap("clamp", "clamp")
    self._gui_placeholder_texture = texture
    return texture
end

local function note_gui_placeholder(renderer, asset_path)
    renderer._gui_image_placeholder_count = (renderer._gui_image_placeholder_count or 0) + 1
    renderer._gui_missing_warned = renderer._gui_missing_warned or {}
    if not renderer._gui_missing_warned[asset_path] then
        renderer._gui_missing_warned[asset_path] = true
        renderer._gui_missing_warned_count = (renderer._gui_missing_warned_count or 0) + 1
        print(string.format("[rbx] image '%s' not found, showing a placeholder", tostring(asset_path)))
    end
    return renderer:_get_gui_placeholder_texture(), "__gui_placeholder"
end

local TEX_PREFETCH_STOP = "__TEXPREFETCH_STOP__"
-- the decode queue overlaps the three-worker contact-AO bake. on the
-- representative 6c/12t host, two texture workers repeatedly left a
-- 0.8-1.1-second main-thread decode tail, three reduced it to about 0.4 seconds
-- and lowered median total load, while four increased AO/build contention and
-- total load. keep smaller machines below that measured contention boundary
local function texture_prefetch_worker_limit(processor_count)
    processor_count = tonumber(processor_count)
    if not processor_count or processor_count ~= processor_count
        or processor_count == math.huge or processor_count == -math.huge then
        return 2
    end
    processor_count = math.max(1, math.floor(processor_count))
    if processor_count < 4 then return 1 end
    if processor_count < 8 then return 2 end
    return 3
end
RBX._texture_prefetch_worker_limit = texture_prefetch_worker_limit
local TEX_PREFETCH_MAX_JOBS = 512
local TEX_PREFETCH_MAX_SOURCE_BYTES = 256 * 1024 * 1024
local TEX_PREFETCH_MAX_DECODED_IMAGE_BYTES = 32 * 1024 * 1024
-- at most one result per worker can be outside the main-thread cache because
-- replacement jobs are dispatched only when a result is drained. Reserve that
-- response/in-flight allowance inside one aggregate resident ceiling
local TEX_PREFETCH_MAX_RESIDENT_BYTES = 256 * 1024 * 1024

function RBX._extract_remote_texture_asset_id(reference)
    return RemoteTexture.extract_asset_id(reference)
end

function RBX._texture_sampler_resource_key(cache_key)
    return "__texture|" .. tostring(cache_key or "__empty")
end

local function remote_texture_now(manager)
    if manager and type(manager.now) == "function" then
        return manager.now()
    end
    if love and love.timer and love.timer.getTime then
        return love.timer.getTime()
    end
    return os.clock()
end

local function remote_texture_resource_released(resource)
    if resource == nil then return false end
    local resource_type = type(resource)
    if resource_type ~= "table" and resource_type ~= "userdata" then
        return false
    end
    -- Binding targets can be arbitrary renderer-side records (including GUI
    -- elements with metatable-backed accessors).  Inspect lifecycle sentinels
    -- without invoking user/runtime metamethods while publishing an asset
    if resource_type == "table"
        and (rawget(resource, "_released") == true
            or rawget(resource, "released") == true
            or rawget(resource, "_destroyed") == true
            or rawget(resource, "destroyed") == true) then
        return true
    end
    local field_ok, is_released = pcall(function()
        return resource.isReleased
    end)
    if not field_ok then return false end
    if type(is_released) == "function" then
        local ok, released = pcall(is_released, resource)
        return ok and released == true
    end
    return false
end

local function remote_texture_binding_stats(renderer)
    local manager = renderer and renderer._remote_texture_manager
    return manager and manager.stats or nil
end

local function remote_texture_clear_sampler_cache(renderer, handle)
    local sampler_key = type(handle) == "table" and handle.sampler_key or nil
    if type(sampler_key) ~= "string" then return false end
    if renderer._texture_cache then renderer._texture_cache[sampler_key] = nil end
    if renderer._texture_cache_missing then
        renderer._texture_cache_missing[sampler_key] = nil
    end
    if renderer._texture_cache_resolved then
        renderer._texture_cache_resolved[sampler_key] = nil
    end
    local stats = remote_texture_binding_stats(renderer)
    if stats then stats.gpu_cache_resets = (stats.gpu_cache_resets or 0) + 1 end
    return true
end

local function remote_texture_retry_less(left, right)
    if left.due ~= right.due then return left.due < right.due end
    return left.sequence < right.sequence
end

local function remote_texture_retry_heap_push(renderer, entry)
    local heap = renderer._remote_texture_gpu_retry_heap
    if not heap then
        heap = {}
        renderer._remote_texture_gpu_retry_heap = heap
    end
    local index = #heap + 1
    heap[index] = entry
    while index > 1 do
        local parent = math.floor(index * 0.5)
        if not remote_texture_retry_less(entry, heap[parent]) then break end
        heap[index] = heap[parent]
        index = parent
    end
    heap[index] = entry
end

local function remote_texture_retry_heap_pop(renderer)
    local heap = renderer._remote_texture_gpu_retry_heap
    local count = heap and #heap or 0
    if count == 0 then return nil end
    local first = heap[1]
    local last = heap[count]
    heap[count] = nil
    count = count - 1
    if count > 0 then
        local index = 1
        while true do
            local left = index * 2
            if left > count then break end
            local right = left + 1
            local child = left
            if right <= count
                and remote_texture_retry_less(heap[right], heap[left]) then
                child = right
            end
            if not remote_texture_retry_less(heap[child], last) then break end
            heap[index] = heap[child]
            index = child
        end
        heap[index] = last
    end
    return first
end

function RBX:_schedule_remote_texture_gpu_retry(handle, now)
    local manager = self._remote_texture_manager
    if type(handle) ~= "table" or not manager
        or self._tearing_down or self._destroyed then
        return false
    end
    if handle.gpu_retry_scheduled == true then return false end
    now = tonumber(now) or remote_texture_now(manager)
    local attempts = math.max(1,
        math.floor(tonumber(handle.gpu_promotion_attempts) or 1))
    local negative = attempts >= (manager.gpu_attempts_before_negative or 4)
    local delay
    if negative then
        delay = manager.gpu_negative_ttl_seconds or 5
        handle.gpu_negative_until = now + delay
        manager.stats.gpu_negative_transitions =
            (manager.stats.gpu_negative_transitions or 0) + 1
    else
        delay = math.min(
            manager.gpu_retry_max_backoff_seconds or 2,
            (manager.gpu_retry_backoff_seconds or 0.05)
                * (2 ^ math.max(0, attempts - 1)))
    end
    self._remote_texture_gpu_retry_sequence =
        (self._remote_texture_gpu_retry_sequence or 0) + 1
    handle.gpu_retry_token = (handle.gpu_retry_token or 0) + 1
    handle.gpu_retry_scheduled = true
    handle.gpu_promotion_next_retry_at = now + delay
    remote_texture_retry_heap_push(self, {
        handle = handle,
        due = handle.gpu_promotion_next_retry_at,
        sequence = self._remote_texture_gpu_retry_sequence,
        token = handle.gpu_retry_token,
        negative = negative,
    })
    manager.stats.gpu_promotion_retries =
        (manager.stats.gpu_promotion_retries or 0) + 1
    return true
end

function RBX:_drain_remote_texture_gpu_retries(now)
    local manager = self._remote_texture_manager
    local heap = self._remote_texture_gpu_retry_heap
    if not manager or not heap then return 0 end
    now = tonumber(now) or remote_texture_now(manager)
    local maximum = manager.max_ready_handles_per_pump or 32
    local drained = 0
    while drained < maximum do
        local first = heap[1]
        if not first or first.due > now then break end
        local entry = remote_texture_retry_heap_pop(self)
        local handle = entry and entry.handle
        if handle and entry.token == handle.gpu_retry_token then
            handle.gpu_retry_scheduled = false
            handle.gpu_promotion_next_retry_at = nil
            if entry.negative then
                handle.gpu_negative_until = nil
                handle.gpu_promotion_attempts = 0
            end
            if handle.state == "ready" then
                self:_enqueue_remote_texture_promotion(handle)
            end
        end
        drained = drained + 1
    end
    return drained
end

function RBX:_drain_remote_texture_ready_sources()
    local manager = self._remote_texture_manager
    local queue = self._remote_texture_ready_source_queue
    if not manager or not queue then return 0 end
    local head = self._remote_texture_ready_source_head or 1
    local tail = self._remote_texture_ready_source_tail or 0
    local maximum = manager.max_ready_handles_per_pump or 32
    local emitted = 0
    while head <= tail and emitted < maximum do
        local source = queue[head]
        local order = source and source.sampler_key_order
        if source and type(order) ~= "table" then
            order = {}
            for sampler_key in pairs(source.sampler_keys or {}) do
                order[#order + 1] = sampler_key
            end
            table.sort(order)
            source.sampler_key_order = order
        end
        local cursor = source and (source._renderer_fanout_cursor or 1) or 1
        while source and cursor <= #order and emitted < maximum do
            local sampler_key = order[cursor]
            cursor = cursor + 1
            local handle = manager.sampler_handles[sampler_key]
            local revision = tonumber(source.revision) or 0
            if handle and handle.source == source
                and (tonumber(handle._fanout_source_revision) or -1) < revision then
                handle._fanout_source_revision = revision
                self:_enqueue_remote_texture_promotion(handle)
                manager.stats.ready_handle_fanout =
                    (manager.stats.ready_handle_fanout or 0) + 1
                emitted = emitted + 1
            end
        end
        if source then source._renderer_fanout_cursor = cursor end
        if not source or cursor > #order then
            if source then source._renderer_fanout_queued = false end
            queue[head] = nil
            head = head + 1
        end
    end
    self._remote_texture_ready_source_head = head
    if head > tail then
        self._remote_texture_ready_source_queue = {}
        self._remote_texture_ready_source_head = 1
        self._remote_texture_ready_source_tail = 0
    end
    return emitted
end

-- generic renderer-lifetime binding record.  handles own weak target keys, the
-- record itself never stores its target.  the field/callback vocabulary is
-- deliberately role-agnostic so future material-map slots can use the same
-- publication path without changing acquisition state
function RBX:_bind_remote_texture_consumer(handle, target, options)
    if type(handle) ~= "table" or target == nil
        or self._tearing_down or self._destroyed then
        return false
    end
    options = options or {}
    local bindings = handle.live_bindings
    if type(bindings) ~= "table" then
        bindings = setmetatable({}, { __mode = "k" })
        handle.live_bindings = bindings
    end
    local roles = bindings[target]
    if not roles then
        roles = {}
        bindings[target] = roles
    end
    local role = tostring(options.role or "texture")
    local target_slots = self._remote_texture_target_slots
    if not target_slots then
        target_slots = setmetatable({}, { __mode = "k" })
        self._remote_texture_target_slots = target_slots
    end
    local target_roles = target_slots[target]
    if not target_roles then
        target_roles = {}
        target_slots[target] = target_roles
    end
    local previous_handle = target_roles[role]
    if previous_handle and previous_handle ~= handle then
        local previous_bindings = previous_handle.live_bindings
        local previous_roles = type(previous_bindings) == "table"
            and previous_bindings[target] or nil
        if type(previous_roles) == "table" then
            previous_roles[role] = nil
            if next(previous_roles) == nil then
                previous_bindings[target] = nil
            end
        end
    end
    target_roles[role] = handle
    local uniform_field = options.uniform_state_key_field
    local uniform_base
    if uniform_field and type(target) == "table" then
        uniform_base = target[uniform_field]
    end
    local scene_generation = nil
    if options.scene_bound ~= false then
        scene_generation = options.scene_generation ~= nil
            and options.scene_generation or (self._instance_generation or 0)
    end
    local revision_field = nil
    if options.revision_field ~= false then
        revision_field = options.revision_field
            or (type(target) == "table" and "remote_texture_revision" or nil)
    end
    local record = {
        role = role,
        renderer_generation = self._remote_texture_binding_generation or 0,
        scene_generation = scene_generation,
        texture_field = options.texture_field,
        resource_key_field = options.resource_key_field,
        resolved_path_field = options.resolved_path_field,
        revision_field = revision_field,
        uniform_state_key_field = uniform_field,
        uniform_state_key_base = uniform_base,
        mesh_field = options.mesh_field,
        target_is_mesh = options.target_is_mesh == true,
        callback = options.callback,
        fallback_rebuild = options.fallback_rebuild == true,
        fallback_reason = options.fallback_reason,
        slot = options.slot,
        expected_asset_path = options.expected_asset_path,
    }
    roles[role] = record
    if handle.materialized == true and handle.texture ~= nil
        and handle.stable_resource_key ~= nil then
        local applied, status =
            self:_apply_remote_texture_binding(handle, target, record)
        local stats = remote_texture_binding_stats(self)
        if applied and stats then
            stats.bound_targets_updated =
                (stats.bound_targets_updated or 0) + 1
        elseif stats then
            if status == "stale" then
                stats.stale_bindings = (stats.stale_bindings or 0) + 1
            else
                stats.failed_bindings = (stats.failed_bindings or 0) + 1
            end
        end
    end
    return true
end

function RBX:_note_remote_texture_non_rebind_consumer(handle, reason)
    if type(handle) ~= "table" then return false end
    local reasons = handle.fallback_rebuild_reasons
    if not reasons then
        reasons = {}
        handle.fallback_rebuild_reasons = reasons
    end
    reason = tostring(reason or "non_rebind_consumer")
    local generation = self._instance_generation or 0
    if reasons[reason] == generation then return false end
    -- handles live across map reloads, but atlas pixels/UVs do not. Stamp the
    -- reason with the scene generation that actually baked this handle so a
    -- late publication cannot dirty an unrelated replacement map
    reasons[reason] = generation
    local stats = remote_texture_binding_stats(self)
    if stats then
        stats.fallback_consumer_count =
            (stats.fallback_consumer_count or 0) + 1
    end
    return true
end

function RBX:_request_remote_texture_fallback_rebuild(handle, reason)
    if self._tearing_down or self._destroyed then return false end
    local revision = tonumber(handle and handle.content_revision) or 0
    local generation = self._instance_generation or 0
    local rebuild_key = tostring(revision) .. ":" .. tostring(generation)
    if handle and handle.fallback_rebuild_key == rebuild_key then
        return false
    end
    if handle then
        handle.fallback_rebuild_key = rebuild_key
        -- keep the legacy field diagnostic-compatible without using it as the
        -- cross-generation dedupe authority
        handle.fallback_rebuild_revision = revision
    end
    -- the texture-atlas path bakes pixels and UVs into another resource and is
    -- the one current consumer that cannot be rebound in place
    if reason == "mesh_texture_atlas" then
        self._mesh_texture_atlas = nil
        self._mesh_atlas_candidates = nil
        self._mesh_atlas_built = false
    end
    self._parts_dirty = true
    self._parts_dirty_mode = "full"
    local stats = remote_texture_binding_stats(self)
    if stats then
        stats.fallback_rebuilds = (stats.fallback_rebuilds or 0) + 1
    end
    return true
end

function RBX:_apply_remote_texture_binding(handle, target, record)
    if type(handle) ~= "table" or target == nil or type(record) ~= "table"
        or self._tearing_down or self._destroyed then
        return false, "stale"
    end
    if record.renderer_generation ~= (self._remote_texture_binding_generation or 0)
        or (record.scene_generation ~= nil
            and record.scene_generation ~= (self._instance_generation or 0))
        or remote_texture_resource_released(target) then
        return false, "stale"
    end
    local target_roles = self._remote_texture_target_slots
        and self._remote_texture_target_slots[target]
    if not target_roles or target_roles[record.role] ~= handle then
        return false, "stale"
    end
    local texture = handle.texture
    if texture == nil or remote_texture_resource_released(texture) then
        return false, "failed"
    end
    local resource_key = handle.stable_resource_key or handle.resource_key
    local content_revision = tonumber(handle.content_revision)
        or tonumber(handle.revision) or 0
    local mesh = record.target_is_mesh and target
        or (record.mesh_field and target[record.mesh_field] or nil)
    if mesh ~= nil and remote_texture_resource_released(mesh) then
        return false, "stale"
    end
    local ok, error_message = pcall(function()
        if record.texture_field then target[record.texture_field] = texture end
        if record.resource_key_field then
            target[record.resource_key_field] = resource_key
        end
        if record.resolved_path_field then
            target[record.resolved_path_field] = handle.resolved_path
        end
        if record.revision_field then
            target[record.revision_field] = content_revision
        end
        if record.uniform_state_key_field then
            target[record.uniform_state_key_field] =
                tostring(record.uniform_state_key_base or "remote_texture")
                    .. "|rt:" .. tostring(resource_key)
                    .. "|r:" .. tostring(content_revision)
        end

        if mesh ~= nil then
            if type(mesh.setTexture) ~= "function" then
                error("texture consumer mesh has no setTexture", 0)
            end
            mesh:setTexture(texture)
            -- Source readiness can precede this budgeted GPU publication
            -- Cached shadow commands retain the live Mesh, but their atlas
            -- still contains its previous alpha coverage. invalidate after
            -- the sampler changes, even if the later callback fails. this
            -- also covers binding an already-materialized handle in place
            self._directional_shadow_atlas_key = nil
        end
        if type(record.callback) == "function" then
            local applied, reason = record.callback(
                self, target, texture, resource_key, handle, record)
            if applied == false then
                error(tostring(reason or "binding callback rejected promotion"), 0)
            end
        end
    end)
    if not ok then
        return false, "failed", error_message
    end
    return true
end

function RBX:_enqueue_remote_texture_promotion(handle)
    if type(handle) ~= "table" or handle.state ~= "ready"
        or self._tearing_down or self._destroyed then
        return false
    end
    local source_revision = tonumber(handle.source and handle.source.revision)
        or tonumber(handle.revision) or 0
    if handle.promoted == true
        and (tonumber(handle.content_revision) or -1) >= source_revision then
        return false
    end
    if handle.gpu_retry_scheduled == true then return false end
    if handle.promotion_queued == true then return false end
    local queue = self._remote_texture_promotion_queue
    if not queue then
        queue = {}
        self._remote_texture_promotion_queue = queue
        self._remote_texture_promotion_head = 1
        self._remote_texture_promotion_tail = 0
    end
    local tail = (self._remote_texture_promotion_tail or 0) + 1
    self._remote_texture_promotion_tail = tail
    queue[tail] = handle
    handle.promotion_queued = true
    local stats = remote_texture_binding_stats(self)
    if stats then
        stats.ready_handles_queued = (stats.ready_handles_queued or 0) + 1
        stats.promotion_queue_depth = tail
            - (self._remote_texture_promotion_head or 1) + 1
    end
    return true
end

function RBX:_publish_remote_texture_handle(handle, texture, resource_key)
    if type(handle) ~= "table" or texture == nil then return false end
    -- invalidate any stale heap entry before exposing the new resource
    handle.gpu_retry_token = (handle.gpu_retry_token or 0) + 1
    handle.gpu_retry_scheduled = false
    handle.gpu_promotion_next_retry_at = nil
    handle.gpu_negative_until = nil
    handle.gpu_promotion_attempts = 0
    handle.texture = texture
    handle.resource_key = resource_key
    handle.stable_resource_key = resource_key
    handle.resolved_path = handle.resolved_path
        or (handle.source and handle.source.cache_path)
        or handle.cache_path
    handle.resolved_debug_path = handle.resolved_path
    handle.promoted_revision = (handle.promoted_revision or 0) + 1
    handle.content_revision = tonumber(handle.source and handle.source.revision)
        or tonumber(handle.revision) or handle.promoted_revision
    handle.promoted = true
    handle.materialized = true
    handle.pending = false
    handle.ready = true

    local stats = remote_texture_binding_stats(self)
    if stats then stats.gpu_promotions = (stats.gpu_promotions or 0) + 1 end
    local bindings = handle.live_bindings
    if type(bindings) == "table" then
        for target, roles in pairs(bindings) do
            local target_updated = false
            for role, record in pairs(roles) do
                local applied, status =
                    self:_apply_remote_texture_binding(handle, target, record)
                if applied then
                    target_updated = true
                elseif status == "stale" then
                    roles[role] = nil
                    if stats then
                        stats.stale_bindings = (stats.stale_bindings or 0) + 1
                    end
                else
                    if stats then
                        stats.failed_bindings = (stats.failed_bindings or 0) + 1
                    end
                    if record.fallback_rebuild then
                        self:_request_remote_texture_fallback_rebuild(
                            handle, record.fallback_reason or role)
                    end
                end
            end
            if next(roles) == nil then bindings[target] = nil end
            if target_updated and stats then
                stats.bound_targets_updated =
                    (stats.bound_targets_updated or 0) + 1
            end
        end
    end
    local current_generation = self._instance_generation or 0
    for reason, generation in pairs(handle.fallback_rebuild_reasons or {}) do
        if generation == current_generation then
            self:_request_remote_texture_fallback_rebuild(handle, reason)
        end
    end
    return true
end

function RBX:_get_remote_texture_manager()
    if self._remote_texture_manager then
        return self._remote_texture_manager
    end
    local configured = self._remote_texture_manager_options or {}
    local options = {}
    for key, value in pairs(configured) do options[key] = value end
    options.enabled = self.allow_remote_asset_fetch == true
    self._remote_texture_manager = RemoteTexture.new(self, options)
    return self._remote_texture_manager
end

function RBX:_on_remote_texture_source_ready(source)
    self._remote_texture_asset_revision =
        (self._remote_texture_asset_revision or 0) + 1
    if type(source) ~= "table" then return end
    local revision = tonumber(source.revision) or 0
    local already_queued = source._renderer_fanout_queued == true
    if already_queued
        and source._renderer_fanout_revision == revision then
        return
    end
    -- Completion callbacks stay O(1). a source may feed hundreds of sampler
    -- variants, update() fans them out deterministically under a hard budget
    source._renderer_fanout_revision = revision
    source._renderer_fanout_cursor = 1
    source._renderer_fanout_queued = true
    if already_queued then return end
    local queue = self._remote_texture_ready_source_queue
    if not queue then
        queue = {}
        self._remote_texture_ready_source_queue = queue
        self._remote_texture_ready_source_head = 1
        self._remote_texture_ready_source_tail = 0
    end
    local tail = (self._remote_texture_ready_source_tail or 0) + 1
    self._remote_texture_ready_source_tail = tail
    queue[tail] = source
end

-- Network completion, GPU upload, and live resource mutation are all pumped
-- from update(), never a draw callback. both completion and publication work
-- have independent count/time budgets
function RBX:_pump_remote_texture_assets()
    local manager = self._remote_texture_manager
    if not manager then return 0, 0, 0 end
    local processed, ready = manager:pump()
    if self._tearing_down or self._destroyed then return processed, ready, 0 end

    local started = remote_texture_now(manager)
    self:_drain_remote_texture_ready_sources()
    self:_drain_remote_texture_gpu_retries(started)
    local upload_ms = 0
    local promoted = 0
    local attempted = 0
    local retry_handles = {}
    local maximum = manager.max_promotions_per_pump or 2
    local budget = manager.promotion_budget_seconds or 0.002
    local queue = self._remote_texture_promotion_queue
    local head = self._remote_texture_promotion_head or 1
    local tail = self._remote_texture_promotion_tail or 0
    while queue and head <= tail and attempted < maximum do
        local handle = queue[head]
        queue[head] = nil
        head = head + 1
        attempted = attempted + 1
        if handle then handle.promotion_queued = false end
        if handle and handle.state == "ready" then
            -- a failed decode/upload stores the placeholder in the ordinary
            -- sampler cache. clear it on every bounded retry so a transient
            -- failure cannot turn into a permanent false cache hit
            remote_texture_clear_sampler_cache(self, handle)
            local upload_started = remote_texture_now(manager)
            local texture, resource_key = self:_get_or_load_texture(
                handle.asset_path, handle.options)
            local upload_elapsed = math.max(
                0, remote_texture_now(manager) - upload_started)
            upload_ms = upload_ms + upload_elapsed * 1000
            local stable = texture ~= nil and type(resource_key) == "string"
                and resource_key:sub(1, 10) == "__texture|"
            if stable then
                self:_publish_remote_texture_handle(
                    handle, texture, resource_key)
                promoted = promoted + 1
            else
                handle.gpu_promotion_attempts =
                    (handle.gpu_promotion_attempts or 0) + 1
                manager.stats.gpu_promotion_failures =
                    (manager.stats.gpu_promotion_failures or 0) + 1
                retry_handles[#retry_handles + 1] = handle
            end
        else
            manager.stats.stale_bindings =
                (manager.stats.stale_bindings or 0) + 1
        end
        if attempted > 0 and remote_texture_now(manager) - started >= budget then
            break
        end
    end
    self._remote_texture_promotion_head = head
    if head > tail then
        self._remote_texture_promotion_queue = {}
        self._remote_texture_promotion_head = 1
        self._remote_texture_promotion_tail = 0
        head, tail = 1, 0
    end
    for index = 1, #retry_handles do
        self:_schedule_remote_texture_gpu_retry(
            retry_handles[index], remote_texture_now(manager))
    end
    head = self._remote_texture_promotion_head or 1
    tail = self._remote_texture_promotion_tail or 0
    if self._remote_sky_derived_dirty
        and type(self._flush_remote_sky_texture_promotions) == "function" then
        local flushed = pcall(self._flush_remote_sky_texture_promotions, self)
        if not flushed then
            manager.stats.failed_bindings =
                (manager.stats.failed_bindings or 0) + 1
        end
    end
    local elapsed_ms = math.max(0, (remote_texture_now(manager) - started) * 1000)
    manager.stats.promotion_queue_depth = math.max(0, tail - head + 1)
    manager.stats.promotion_ms_last = elapsed_ms
    manager.stats.promotion_ms_total =
        (manager.stats.promotion_ms_total or 0) + elapsed_ms
    manager.stats.promotion_ms_max = math.max(
        manager.stats.promotion_ms_max or 0, elapsed_ms)
    manager.stats.promotion_upload_ms_last = upload_ms
    manager.stats.promotion_upload_ms_total =
        (manager.stats.promotion_upload_ms_total or 0) + upload_ms
    manager.stats.promotion_upload_ms_max = math.max(
        manager.stats.promotion_upload_ms_max or 0, upload_ms)
    return processed, ready, promoted
end

function RBX:_stop_remote_texture_assets()
    local manager = self._remote_texture_manager
    local had_state = manager ~= nil
        or self._remote_texture_promotion_queue ~= nil
    self._remote_texture_binding_generation =
        (self._remote_texture_binding_generation or 0) + 1
    for _, handle in pairs(self._remote_texture_promotion_queue or {}) do
        if type(handle) == "table" then
            handle.promotion_queued = false
            handle.live_bindings = nil
        end
    end
    for _, entry in pairs(self._remote_texture_gpu_retry_heap or {}) do
        local handle = type(entry) == "table" and entry.handle or nil
        if type(handle) == "table" then
            handle.gpu_retry_token = (handle.gpu_retry_token or 0) + 1
            handle.gpu_retry_scheduled = false
            handle.gpu_promotion_next_retry_at = nil
        end
    end
    for _, source in pairs(self._remote_texture_ready_source_queue or {}) do
        if type(source) == "table" then
            source._renderer_fanout_queued = false
            source._renderer_fanout_cursor = nil
        end
    end
    self._remote_texture_promotion_queue = nil
    self._remote_texture_promotion_head = nil
    self._remote_texture_promotion_tail = nil
    self._remote_texture_gpu_retry_heap = nil
    self._remote_texture_gpu_retry_sequence = nil
    self._remote_texture_ready_source_queue = nil
    self._remote_texture_ready_source_head = nil
    self._remote_texture_ready_source_tail = nil
    self._remote_texture_target_slots = nil
    self._remote_sky_derived_dirty = nil
    local stopped = manager and manager:stop() or false
    if manager then
        manager.stats.promotion_queue_depth = 0
        self._remote_texture_last_stats = manager:get_stats()
    end
    self._remote_texture_manager = nil
    return stopped or had_state
end

function RBX:_get_remote_texture_asset_stats()
    if self._remote_texture_manager then
        return self._remote_texture_manager:get_stats()
    end
    local stats = {}
    for key, value in pairs(self._remote_texture_last_stats or {}) do stats[key] = value end
    stats.enabled = self.allow_remote_asset_fetch == true
    stats.source_count = stats.source_count or 0
    stats.pending_sources = stats.pending_sources or 0
    stats.ready_sources = stats.ready_sources or 0
    stats.negative_sources = stats.negative_sources or 0
    stats.outstanding = stats.outstanding or 0
    stats.ready_handles_queued = stats.ready_handles_queued or 0
    stats.gpu_promotions = stats.gpu_promotions or 0
    stats.gpu_promotion_failures = stats.gpu_promotion_failures or 0
    stats.gpu_promotion_retries = stats.gpu_promotion_retries or 0
    stats.gpu_negative_transitions = stats.gpu_negative_transitions or 0
    stats.gpu_cache_resets = stats.gpu_cache_resets or 0
    stats.ready_handle_fanout = stats.ready_handle_fanout or 0
    stats.bound_targets_updated = stats.bound_targets_updated or 0
    stats.stale_bindings = stats.stale_bindings or 0
    stats.failed_bindings = stats.failed_bindings or 0
    stats.fallback_rebuilds = stats.fallback_rebuilds or 0
    stats.promotion_queue_depth = stats.promotion_queue_depth or 0
    return stats
end

-- Remote mesh bytes and CPU decoding use their own bounded pipeline.  the
-- manager deliberately owns decoded tables until teardown, scene consumers
-- only hold weak bindings and read a stable variant handle
function RBX:_get_remote_mesh_manager()
    if self._remote_mesh_manager then
        return self._remote_mesh_manager
    end
    local configured = self._remote_mesh_manager_options or {}
    local options = {}
    for key, value in pairs(configured) do options[key] = value end
    options.enabled = self.allow_remote_mesh_fetch == true
    options.decoder_module = options.decoder_module
        or "engine/graphics/rbx/runtime/remote_mesh_decoder"
    -- per-variant callbacks are bookkeeping-only. Scene mutation is coalesced
    -- by the manager's quiet-window wave callback below
    options.notify_variant_ready = true
    self._remote_mesh_manager = RemoteMesh.new(self, options)
    return self._remote_mesh_manager
end

local function clear_part_mesh_lod_state(part)
    if type(part) ~= "table" then return end
    part._mesh_lod_base_mesh = nil
    part._mesh_lod_count = nil
    part._mesh_lod_index = nil
    part._mesh_lod_fidelity = nil
    part._mesh_lod_projected_pixels = nil
end

function RBX:_unbind_remote_mesh_consumer(consumer)
    if type(consumer) ~= "table" then return false end
    local handle = rawget(consumer, "_remote_mesh_handle")
    local had_remote_binding = handle ~= nil
        or rawget(consumer, "_remote_mesh_variant_key") ~= nil
    local manager = self._remote_mesh_manager
    local unbound = false
    if handle and manager and type(manager.unbind) == "function" then
        unbound = manager:unbind(handle, consumer) == true
    end
    rawset(consumer, "_remote_mesh_handle", nil)
    rawset(consumer, "_remote_mesh_variant_key", nil)
    -- a terminal/unbound handle no longer owns the decoded graph. Consumers
    -- must not keep an old render_lods tree alive (or reuse its committed index)
    -- while a replacement is absent or pending
    if had_remote_binding then
        clear_part_mesh_lod_state(consumer)
    end
    return unbound
end

function RBX:_on_remote_mesh_variant_ready(handle)
    if type(handle) ~= "table" or self._tearing_down or self._destroyed then
        return false
    end
    if handle.ready ~= true or handle.result == nil then
        return false
    end
    if handle._renderer_counted_ready ~= true then
        handle._renderer_counted_ready = true
        self.unique_mesh_count = (self.unique_mesh_count or 0) + 1
    end

    -- the manager records consumers in weak, stable slots as they bind.  keep
    -- only the ready handle in this queue: snapshotting a popular mesh's weak
    -- consumer map here would turn one worker completion into an unbounded main
    -- thread allocation/iteration spike
    local order = handle.consumer_order
    local tail = math.max(0, math.floor(
        tonumber(handle.consumer_order_count) or 0))
    if type(order) ~= "table" then
        -- an injected/older manager without the ordered-consumer contract
        -- cannot be promoted safely in slices. preserve correctness with the
        -- explicitly rare full fallback at wave settlement
        self._remote_mesh_full_rebuild_pending = true
        self._remote_mesh_missing_consumer_order_count =
            (self._remote_mesh_missing_consumer_order_count or 0) + 1
        return false
    end
    if tail <= 0 then
        return true
    end

    local revision = math.max(1, math.floor(tonumber(handle.revision) or 1))
    if (tonumber(handle._renderer_fanout_completed_revision) or 0) >= revision then
        return true
    end
    local entry = handle._renderer_fanout_record
    if entry and entry.renderer == self and entry.queued == true then
        if revision > (tonumber(entry.revision) or 0) then
            -- a source refresh supersedes an unfinished older publication
            -- Restarting the weak-slot walk guarantees consumers already
            -- rebuilt for the old result are dirtied once for the new result
            entry.revision = revision
            entry.cursor = 1
            entry.tail = tail
        else
            entry.tail = math.max(entry.tail or 0, tail)
        end
        return true
    end

    local queue = self._remote_mesh_ready_queue
    if not queue then
        queue = {}
        self._remote_mesh_ready_queue = queue
        self._remote_mesh_ready_head = 1
        self._remote_mesh_ready_tail = 0
    end
    local queue_tail = (self._remote_mesh_ready_tail or 0) + 1
    entry = {
        renderer = self,
        handle = handle,
        revision = revision,
        cursor = 1,
        tail = tail,
        queued = true,
    }
    queue[queue_tail] = entry
    self._remote_mesh_ready_tail = queue_tail
    handle._renderer_fanout_record = entry
    return true
end

function RBX:_clear_remote_mesh_promotion_queue()
    local queue = self._remote_mesh_ready_queue
    local head = self._remote_mesh_ready_head or 1
    local tail = self._remote_mesh_ready_tail or 0
    if queue then
        for index = head, tail do
            local entry = queue[index]
            if entry then
                entry.queued = false
                local handle = entry.handle
                if type(handle) == "table"
                    and handle._renderer_fanout_record == entry then
                    handle._renderer_fanout_record = nil
                end
                entry.handle = nil
                entry.renderer = nil
                queue[index] = nil
            end
        end
    end
    self._remote_mesh_ready_queue = nil
    self._remote_mesh_ready_head = nil
    self._remote_mesh_ready_tail = nil
    return math.max(0, tail - head + 1)
end

local function retire_remote_mesh_fanout_entry(entry, completed_revision)
    if type(entry) ~= "table" then return end
    entry.queued = false
    local handle = entry.handle
    if type(handle) == "table" then
        if completed_revision ~= nil then
            handle._renderer_fanout_completed_revision = math.max(
                tonumber(handle._renderer_fanout_completed_revision) or 0,
                tonumber(completed_revision) or 0)
        end
        if handle._renderer_fanout_record == entry then
            handle._renderer_fanout_record = nil
        end
    end
    -- both links are strong. clear them on every retirement path so an
    -- externally retained/evicted handle cannot keep the renderer alive
    entry.handle = nil
    entry.renderer = nil
end

local function remote_mesh_consumer_is_current(renderer, handle, consumer,
        slot, publication_revision)
    if type(consumer) ~= "table" or consumer._destroyed
        -- CSG child-data decoding builds short-lived negative-id runtime parts
        -- so nested local geometry can reuse the normal mesh resolver. those
        -- decode probes may request a remote source, but they are not scene
        -- instances and must never enter static-range promotion (which would
        -- otherwise force a whole-map rebuild when publication completes)
        or consumer._id == nil
        or (type(renderer._runtime_part_by_id) == "table"
            and renderer._runtime_part_by_id[consumer._id] ~= consumer)
        or rawget(consumer, "_remote_mesh_handle") ~= handle
        or rawget(consumer, "_remote_mesh_variant_key") ~= handle.variant_key
        or type(handle.consumers) ~= "table"
        or handle.consumers[consumer] == nil
        or type(handle.consumer_slots) ~= "table"
        or handle.consumer_slots[consumer] ~= slot
        or type(handle.consumer_bind_revision) ~= "table"
        or handle.consumer_bind_revision[slot] == nil
        or handle.ready ~= true or handle.result == nil then
        return false
    end
    local result_revision = type(handle.consumer_result_revision) == "table"
        and tonumber(handle.consumer_result_revision[slot]) or 0
    -- a consumer bound after this result was published received the ready mesh
    -- synchronously from _get_or_parse_mesh and has no fallback geometry to
    -- retire. it should participate only in a later source refresh
    if result_revision >= publication_revision then
        return false
    end

    local mesh_source = consumer.MeshId
    if (type(mesh_source) ~= "string" or trim(mesh_source) == "")
        and RBX._get_default_part_mesh_asset_path then
        mesh_source = RBX._get_default_part_mesh_asset_path(consumer)
    end
    local expected_id = extract_asset_id(mesh_source)
    local expected_type = is_csg_part_class(consumer.ClassName)
        and "csg_mesh" or "mesh"
    return expected_id ~= nil
        and tostring(expected_id) == tostring(handle.asset_id)
        and expected_type == handle.asset_type
end

local function acknowledge_remote_mesh_consumer_revision(handle, consumer,
        slot, bind_revision, publication_revision)
    if type(handle) ~= "table" or type(consumer) ~= "table"
        or type(handle.consumer_order) ~= "table"
        or handle.consumer_order[slot] ~= consumer
        or type(handle.consumer_slots) ~= "table"
        or handle.consumer_slots[consumer] ~= slot
        or type(handle.consumers) ~= "table"
        or handle.consumers[consumer] == nil
        or type(handle.consumer_bind_revision) ~= "table"
        or handle.consumer_bind_revision[slot] ~= bind_revision
        or rawget(consumer, "_remote_mesh_handle") ~= handle
        or rawget(consumer, "_remote_mesh_variant_key")
            ~= handle.variant_key
        or type(handle.consumer_result_revision) ~= "table" then
        return false
    end
    handle.consumer_result_revision[slot] = math.max(
        tonumber(handle.consumer_result_revision[slot]) or 0,
        tonumber(publication_revision) or 0)
    return true
end

-- a successful full scene build has already resolved every current part
-- against the ready handles visible on the main thread. Acknowledge that fact
-- only at the build commit (scene.lua calls this from its non-throwing
-- epilogue), then retire publications that would otherwise re-promote the
-- freshly rebuilt static parts into thousands of one-part dynamic chunks
function RBX:_acknowledge_remote_mesh_full_build(observed_consumers)
    if self._tearing_down or self._destroyed then return 0, 0 end
    local acknowledged = 0
    local preserve_unordered_fallback = false
    for index = 1, #(self.parts or {}) do
        local consumer = self.parts[index]
        local handle = type(consumer) == "table"
            and rawget(consumer, "_remote_mesh_handle") or nil
        local slot = type(handle) == "table"
            and type(handle.consumer_slots) == "table"
            and handle.consumer_slots[consumer] or nil
        local bind_revision = slot ~= nil
            and type(handle.consumer_bind_revision) == "table"
            and handle.consumer_bind_revision[slot] or nil
        local observed = observed_consumers == nil
        if not observed and type(observed_consumers) == "table" then
            local record = observed_consumers[consumer]
            observed = type(record) == "table"
                and record.handle == handle
                and (tonumber(record.revision) or 0)
                    >= (tonumber(handle and handle.revision) or 0)
                and (slot == nil or (record.slot == slot
                    and record.bind_revision == bind_revision))
        end
        if type(handle) == "table" and handle.ready == true
            and handle.result ~= nil
            and type(handle.consumer_order) ~= "table"
            and not observed then
            -- Compatibility managers without stable consumer slots cannot
            -- enqueue incremental fanout. if this async build did not actually
            -- observe their publication, preserve the explicit full fallback
            -- for the next pump instead of silently losing the mesh update
            preserve_unordered_fallback = true
        end
        if observed and slot ~= nil and bind_revision ~= nil
            and handle.ready == true and handle.result ~= nil
            and acknowledge_remote_mesh_consumer_revision(
                handle, consumer, slot, bind_revision,
                handle.revision) then
            acknowledged = acknowledged + 1
        end
    end

    local queue = self._remote_mesh_ready_queue
    local head = self._remote_mesh_ready_head or 1
    local tail = self._remote_mesh_ready_tail or 0
    local can_retire_queue = true
    for index = head, tail do
        local entry = queue and queue[index] or nil
        local handle = entry and entry.handle or nil
        if entry and entry.queued == true then
            local publication_revision =
                math.max(0, tonumber(entry.revision) or 0)
            if type(handle) ~= "table" or handle.ready ~= true
                or handle.result == nil
                or (tonumber(handle.revision) or 0)
                    < publication_revision then
                can_retire_queue = false
                break
            end
            local entry_tail = math.max(0, math.floor(
                tonumber(entry.tail) or 0))
            for slot = 1, entry_tail do
                if remote_mesh_consumer_is_current(
                        self,
                        handle,
                        handle.consumer_order[slot],
                        slot,
                        publication_revision) then
                    can_retire_queue = false
                    break
                end
            end
            if not can_retire_queue then break end
        end
    end

    local retired = 0
    if can_retire_queue and queue then
        for index = head, tail do
            local entry = queue[index]
            local handle = entry and entry.handle or nil
            if entry and entry.queued == true
                and type(handle) == "table" then
                handle._renderer_fanout_completed_revision = math.max(
                    tonumber(handle._renderer_fanout_completed_revision) or 0,
                    tonumber(entry.revision) or 0)
            end
        end
        retired = self:_clear_remote_mesh_promotion_queue()
    end
    self._remote_mesh_full_rebuild_pending =
        preserve_unordered_fallback and true or false
    self._remote_mesh_full_build_acknowledged_count =
        (self._remote_mesh_full_build_acknowledged_count or 0)
            + acknowledged
    self._remote_mesh_full_build_queue_retired_count =
        (self._remote_mesh_full_build_queue_retired_count or 0) + retired
    return acknowledged, retired
end

function RBX:_commit_remote_mesh_full_fallback()
    if self._remote_mesh_full_rebuild_pending ~= true
        or self._tearing_down or self._destroyed then
        return false
    end
    self._remote_mesh_full_rebuild_pending = false
    self:_clear_remote_mesh_promotion_queue()
    -- the global revision is intentionally advanced only on the rare fallback:
    -- it invalidates every part's bounds cache. incremental publication clears
    -- just the affected part caches in scene.lua
    self._remote_mesh_asset_revision =
        (self._remote_mesh_asset_revision or 0) + 1
    self._remote_mesh_wave_rebuild_count =
        (self._remote_mesh_wave_rebuild_count or 0) + 1
    self._parts_dirty = true
    self._parts_dirty_mode = "full"
    return true
end

function RBX:_drain_remote_mesh_ready_consumers(max_promotions, max_scans)
    if self._tearing_down or self._destroyed then
        self:_clear_remote_mesh_promotion_queue()
        return 0, 0, false
    end
    -- Async map builds yield between classification slices while sharing the
    -- same renderer with update(). a ready publication must not inspect or
    -- mutate the incomplete static-range index. the successful full-build
    -- commit acknowledges consumers recorded in _get_or_parse_mesh, anything
    -- published too late for its part remains queued and is promoted next tick
    if self._remote_mesh_full_build_seen ~= nil then
        local head = self._remote_mesh_ready_head or 1
        local tail = self._remote_mesh_ready_tail or 0
        return 0, self._remote_mesh_ready_queue
            and math.max(0, tail - head + 1) or 0, false
    end
    local promotion_limit = math.max(1, math.floor(tonumber(max_promotions)
        or tonumber(self._remote_mesh_promotions_per_pump) or 16))
    local scan_limit = math.max(promotion_limit, math.floor(tonumber(max_scans)
        or tonumber(self._remote_mesh_consumer_scans_per_pump)
        or promotion_limit * 8))
    local queue = self._remote_mesh_ready_queue
    local head = self._remote_mesh_ready_head or 1
    local tail = self._remote_mesh_ready_tail or 0
    local promoted = 0
    local scanned = 0

    while queue and head <= tail and promoted < promotion_limit
        and scanned < scan_limit and self._remote_mesh_full_rebuild_pending ~= true do
        local entry = queue[head]
        local handle = entry and entry.handle
        if not entry or entry.queued ~= true or type(handle) ~= "table"
            or type(handle.consumer_order) ~= "table" then
            retire_remote_mesh_fanout_entry(entry)
            queue[head] = nil
            head = head + 1
        else
            while entry.cursor <= entry.tail and promoted < promotion_limit
                and scanned < scan_limit do
                local slot = entry.cursor
                entry.cursor = slot + 1
                scanned = scanned + 1
                local consumer = handle.consumer_order[slot]
                local bind_revision =
                    type(handle.consumer_bind_revision) == "table"
                    and handle.consumer_bind_revision[slot] or nil
                if remote_mesh_consumer_is_current(
                        self, handle, consumer, slot, entry.revision) then
                    promoted = promoted + 1
                    local call_ok, ok, reason = pcall(
                        self._promote_remote_mesh_part_incrementally,
                        self, consumer)
                    if call_ok and ok then
                        acknowledge_remote_mesh_consumer_revision(
                            handle, consumer, slot, bind_revision,
                            entry.revision)
                        self._remote_mesh_incremental_promotion_count =
                            (self._remote_mesh_incremental_promotion_count or 0) + 1
                    else
                        self._remote_mesh_full_rebuild_pending = true
                        self._remote_mesh_incremental_failure_count =
                            (self._remote_mesh_incremental_failure_count or 0) + 1
                        self._remote_mesh_last_incremental_error = tostring(
                            call_ok and reason or ok
                                or "incremental_promotion_failed")
                        break
                    end
                elseif consumer ~= nil then
                    self._remote_mesh_stale_consumer_count =
                        (self._remote_mesh_stale_consumer_count or 0) + 1
                end
            end
            if entry.cursor > entry.tail then
                retire_remote_mesh_fanout_entry(entry, entry.revision)
                queue[head] = nil
                head = head + 1
            elseif head < tail and (promoted >= promotion_limit
                    or scanned >= scan_limit) then
                -- a mesh shared by thousands of parts must not starve smaller
                -- ready variants behind it. rotate unfinished handles only when
                -- another entry is waiting, a single popular handle keeps a
                -- compact, stable queue index
                queue[head] = nil
                head = head + 1
                tail = tail + 1
                queue[tail] = entry
                self._remote_mesh_ready_tail = tail
            end
        end
    end

    self._remote_mesh_ready_head = head
    if queue and head > tail then
        self._remote_mesh_ready_queue = nil
        self._remote_mesh_ready_head = nil
        self._remote_mesh_ready_tail = nil
        queue = nil
        head, tail = 1, 0
    elseif queue and head > 64 and head > math.floor(tail / 2) then
        local compact = {}
        local count = 0
        for index = head, tail do
            local entry = queue[index]
            if entry then
                count = count + 1
                compact[count] = entry
            end
        end
        self._remote_mesh_ready_queue = compact
        self._remote_mesh_ready_head = 1
        self._remote_mesh_ready_tail = count
        queue = compact
        head, tail = 1, count
    end

    local fell_back = false
    if self._remote_mesh_full_rebuild_pending == true then
        fell_back = self:_commit_remote_mesh_full_fallback()
        queue = self._remote_mesh_ready_queue
        head = self._remote_mesh_ready_head or 1
        tail = self._remote_mesh_ready_tail or 0
    end
    local depth = queue and math.max(0, tail - head + 1) or 0
    return promoted, depth, fell_back
end

function RBX:_on_remote_mesh_wave_settled(snapshot)
    if type(snapshot) ~= "table" or self._tearing_down or self._destroyed
        or (tonumber(snapshot.ready) or 0) <= 0 then
        return false
    end
    self._remote_mesh_wave_revision =
        (self._remote_mesh_wave_revision or 0) + 1
    self._remote_mesh_last_wave = snapshot
    self._remote_mesh_wave_notification_count =
        (self._remote_mesh_wave_notification_count or 0) + 1
    -- Publication fanout is drained after manager:pump returns. a wave is a
    -- diagnostics/coalescing boundary, not a reason to rebake the whole map
    if self._remote_mesh_full_rebuild_pending == true
        and self._remote_mesh_full_build_seen == nil then
        self:_commit_remote_mesh_full_fallback()
    end
    return true
end

function RBX:_pump_remote_mesh_assets()
    local manager = self._remote_mesh_manager
    if not manager or self._tearing_down or self._destroyed then
        return 0, 0, false
    end
    local processed, ready, settled = manager:pump()
    local promoted, queue_depth, fell_back =
        self:_drain_remote_mesh_ready_consumers()
    return processed, ready, settled, promoted, queue_depth, fell_back
end

function RBX:_stop_remote_mesh_assets()
    local manager = self._remote_mesh_manager
    local had_state = manager ~= nil
    local cleared = self:_clear_remote_mesh_promotion_queue()
    self._remote_mesh_full_rebuild_pending = false
    local stopped = manager and manager:stop() or false
    if manager then
        self._remote_mesh_last_stats = manager:get_stats()
    end
    self._remote_mesh_manager = nil
    return stopped or had_state or cleared > 0
end

function RBX:_get_remote_mesh_asset_stats()
    local stats = {}
    local source = self._remote_mesh_manager
        and self._remote_mesh_manager:get_stats()
        or self._remote_mesh_last_stats or {}
    for key, value in pairs(source) do
        stats[key] = value
    end
    stats.enabled = self.allow_remote_mesh_fetch == true
    stats.source_count = stats.source_count or 0
    stats.variant_count = stats.variant_count or 0
    stats.pending_variants = stats.pending_variants or 0
    stats.ready_variants = stats.ready_variants or 0
    stats.negative_variants = stats.negative_variants or 0
    stats.live_consumers = stats.live_consumers or 0
    stats.decode_queue_depth = stats.decode_queue_depth or 0
    stats.decode_outstanding = stats.decode_outstanding or 0
    stats.wave_rebuilds = self._remote_mesh_wave_rebuild_count or 0
    stats.wave_notifications = self._remote_mesh_wave_notification_count or 0
    stats.wave_revision = self._remote_mesh_wave_revision or 0
    stats.incremental_promotions =
        self._remote_mesh_incremental_promotion_count or 0
    stats.incremental_failures =
        self._remote_mesh_incremental_failure_count or 0
    stats.last_incremental_error = self._remote_mesh_last_incremental_error
    stats.stale_consumers = self._remote_mesh_stale_consumer_count or 0
    stats.missing_consumer_order =
        self._remote_mesh_missing_consumer_order_count or 0
    stats.full_build_acknowledged_consumers =
        self._remote_mesh_full_build_acknowledged_count or 0
    stats.full_build_retired_publications =
        self._remote_mesh_full_build_queue_retired_count or 0
    stats.full_build_ack_error = self._remote_mesh_full_build_ack_error
    local head = self._remote_mesh_ready_head or 1
    local tail = self._remote_mesh_ready_tail or 0
    stats.promotion_queue_depth = self._remote_mesh_ready_queue
        and math.max(0, tail - head + 1) or 0
    return stats
end

function RBX:_texture_manifest_file(map_path)
    local key = tostring(map_path or ""):gsub("[^%w]", "_")
    -- v2 excludes generated-only demand. Old hints have no consumer provenance
    -- and may eagerly acquire surface maps for a now-inapplicable mesh owner
    return "texture_manifest/" .. key .. ".v2.manifest"
end

local function texture_prefetch_role_key(path, alpha_bleed)
    return (alpha_bleed and "B\0" or "N\0") .. tostring(path or "")
end
RBX._texture_prefetch_role_key = texture_prefetch_role_key

local function record_texture_manifest_demand(renderer, path, alpha_bleed)
    local manifest = renderer._texture_manifest_paths
    if type(manifest) ~= "table" or type(path) ~= "string" or path == "" then
        return
    end
    local key = texture_prefetch_role_key(path, alpha_bleed)
    if manifest[key] ~= nil then return end
    manifest[key] = {
        path = path,
        alpha_bleed = alpha_bleed == true,
    }
    local order = renderer._texture_manifest_order
    order[#order + 1] = key
end

local function parse_texture_manifest_line(line)
    line = tostring(line or ""):gsub("\r$", "")
    local role, path = line:match("^([BN])\t(.+)$")
    if role then
        return path, role == "B"
    end
    -- v1 manifests contained one resolved path per line and were decode-only
    if line ~= "" then return line, false end
    return nil, false
end

local function parsed_surface_alpha_bleed(surface)
    local mode = type(surface) == "table"
        and tonumber(surface.alpha_mode or surface.raw_alpha_mode
            or surface.AlphaMode) or 0
    return mode ~= 2 and mode ~= 3
end

local function texture_prefetch_image_bytes(data, reported_bytes)
    if data and data.getSize then
        local ok, bytes = pcall(data.getSize, data)
        if ok and tonumber(bytes) and tonumber(bytes) >= 0 then
            return math.floor(tonumber(bytes))
        end
    end
    return math.max(0, math.floor(tonumber(reported_bytes) or 0))
end

local function release_texture_prefetch_entry(renderer, entry)
    if type(entry) ~= "table" or entry.released == true then return false end
    local data = entry.data
    if not data then
        entry.released = true
        return false
    end
    entry.data = nil
    entry.released = true
    if entry.accounted == true then
        renderer._texture_prefetch_cached_bytes = math.max(0,
            (tonumber(renderer._texture_prefetch_cached_bytes) or 0)
                - (tonumber(entry.bytes) or 0))
        entry.accounted = false
    end
    pcall(data.release, data)
    local stats = renderer._texture_prefetch_stats
    if stats then
        stats.released_image_count =
            (tonumber(stats.released_image_count) or 0) + 1
    end
    return true
end

local function store_texture_prefetch_image(
    renderer, key, data, bled, reported_bytes, release_on_reject)
    local cache = renderer._prefetched_image_data
    if type(cache) ~= "table" or not data then return false, nil end
    local previous = cache[key]
    if previous then
        release_texture_prefetch_entry(renderer, previous)
        cache[key] = nil
    end
    local entry = {
        data = data,
        bled = bled == true,
        bytes = texture_prefetch_image_bytes(data, reported_bytes),
    }
    local resident = tonumber(renderer._texture_prefetch_cached_bytes) or 0
    local budget = tonumber(renderer._texture_prefetch_cache_budget_bytes)
        or TEX_PREFETCH_MAX_RESIDENT_BYTES
    if entry.bytes <= TEX_PREFETCH_MAX_DECODED_IMAGE_BYTES
        and resident + entry.bytes <= budget then
        entry.accounted = true
        cache[key] = entry
        renderer._texture_prefetch_cached_bytes = resident + entry.bytes
        local stats = renderer._texture_prefetch_stats
        if stats then
            stats.peak_cached_bytes = math.max(
                tonumber(stats.peak_cached_bytes) or 0,
                renderer._texture_prefetch_cached_bytes)
        end
        return true, entry
    end
    local stats = renderer._texture_prefetch_stats
    if stats then
        stats.dropped_budget_jobs =
            (tonumber(stats.dropped_budget_jobs) or 0) + 1
    end
    if release_on_reject then
        release_texture_prefetch_entry(renderer, entry)
    end
    return false, entry
end

local function dispatch_texture_prefetch_jobs(renderer, count)
    if renderer._texture_prefetch_stopping == true then return 0 end
    local req = renderer._texture_prefetch_req
    local jobs = renderer._texture_prefetch_pending_jobs
    if not req or type(jobs) ~= "table" then return 0 end
    local dispatched = 0
    local next_index = tonumber(renderer._texture_prefetch_next_job) or 1
    while dispatched < math.max(0, math.floor(tonumber(count) or 0))
        and next_index <= #jobs do
        local ok = pcall(req.push, req, jobs[next_index])
        if not ok then break end
        next_index = next_index + 1
        dispatched = dispatched + 1
    end
    renderer._texture_prefetch_next_job = next_index
    renderer._texture_prefetch_inflight =
        (tonumber(renderer._texture_prefetch_inflight) or 0) + dispatched
    local stats = renderer._texture_prefetch_stats
    if stats then
        stats.dispatched_jobs =
            (tonumber(stats.dispatched_jobs) or 0) + dispatched
        stats.peak_inflight_jobs = math.max(
            tonumber(stats.peak_inflight_jobs) or 0,
            tonumber(renderer._texture_prefetch_inflight) or 0)
    end
    return dispatched
end

-- start exact image decode/alpha-bleed work before runtime-part construction
-- parsed authored references make the first boot useful, the ordered manifest
-- supplements that cold preflight with references discovered deeper in the
-- renderer on a prior boot. every result is keyed by path *and* bleed role so
-- a modified transparent RGB payload can never leak into a plain/data sampler
function RBX:_start_texture_prefetch(map_path, parsed_map)
    if self._texture_prefetch_req or self._texture_prefetch_res
        or self._texture_prefetch_threads or self._prefetched_image_data then
        self:_stop_texture_prefetch(nil, false)
    end
    self._texture_manifest_paths = {}
    self._texture_manifest_order = {}
    self._texture_prefetch_stopping = false
    self._texture_prefetch_cached_bytes = 0
    self._texture_prefetch_stats = {
        preflight_jobs = 0,
        manifest_jobs = 0,
        queued_jobs = 0,
        source_bytes = 0,
        completed_jobs = 0,
        failed_jobs = 0,
        alpha_bleed_hits = 0,
        decode_hits = 0,
        worker_decode_seconds = 0,
        worker_alpha_bleed_seconds = 0,
        dispatched_jobs = 0,
        peak_inflight_jobs = 0,
        peak_cached_bytes = 0,
        resident_budget_bytes = 0,
        dropped_budget_jobs = 0,
        released_image_count = 0,
        resident_jobs_skipped = 0,
    }
    -- also serves as a load-scoped CPU ImageData memo for sampler variants
    -- it is released deterministically by _stop_texture_prefetch
    self._prefetched_image_data = {}
    if not (love and love.thread and love.filesystem) then return end

    local jobs, seen = {}, {}
    -- a same-renderer reload retains GPU samplers. Prefetch is only a source
    -- hint: decoding/bleeding an already resident role competes with scene
    -- construction and is never consumed by a sampler-cache hit. build this
    -- set from live cache ownership, not the weak diagnostic registry alone,
    -- so invalidated/negative entries cannot suppress a new decode. a new
    -- sampler variant still uses the normal exact synchronous fallback
    local resident_roles = {}
    local sampler_metadata = self._texture_sampler_debug_by_texture or {}
    local resolved_paths = self._texture_cache_resolved or {}
    local missing = self._texture_cache_missing or {}
    for cache_key, texture in pairs(self._texture_cache or {}) do
        local metadata = sampler_metadata[texture]
        local resolved = resolved_paths[cache_key]
        if not missing[cache_key] and type(metadata) == "table"
            and type(resolved) == "string" and resolved ~= ""
            and metadata.resolved == resolved then
            resident_roles[texture_prefetch_role_key(
                resolved, metadata.alpha_bleed == true)] = true
        end
    end
    local preflight_references_seen = {}
    local source_bytes = 0
    local function append_resolved(path, alpha_bleed, source)
        if type(path) ~= "string" or path == "" then return false end
        local key = texture_prefetch_role_key(path, alpha_bleed)
        if seen[key] then return false end
        if resident_roles[key] then
            seen[key] = true
            self._texture_prefetch_stats.resident_jobs_skipped =
                self._texture_prefetch_stats.resident_jobs_skipped + 1
            -- Descriptor caches can bypass _get_or_load_texture altogether
            -- keep these incoming hints for the next cold process as well
            record_texture_manifest_demand(self, path, alpha_bleed)
            return false
        end
        if #jobs >= TEX_PREFETCH_MAX_JOBS then return false end
        local info
        if love.filesystem.getInfo then
            local ok_info, result = pcall(love.filesystem.getInfo, path, "file")
            if ok_info then info = result end
        end
        local bytes = math.max(0, tonumber(info and info.size) or 0)
        if source_bytes + bytes > TEX_PREFETCH_MAX_SOURCE_BYTES then
            return false
        end
        source_bytes = source_bytes + bytes
        seen[key] = true
        jobs[#jobs + 1] = {
            path = path,
            alpha_bleed = alpha_bleed == true,
            profile = self.collect_hotspot_stats == true,
            max_decoded_bytes = TEX_PREFETCH_MAX_DECODED_IMAGE_BYTES,
        }
        local field = source == "preflight" and "preflight_jobs"
            or "manifest_jobs"
        self._texture_prefetch_stats[field] =
            self._texture_prefetch_stats[field] + 1
        return true
    end
    local function append_reference(reference, alpha_bleed)
        if type(reference) ~= "string" or reference == "" then return end
        local reference_key = texture_prefetch_role_key(
            self:_renderer_asset_cache_key(reference, "texture"), alpha_bleed)
        if preflight_references_seen[reference_key] then return end
        preflight_references_seen[reference_key] = true
        local resolved = self:_resolve_asset_path(reference, "texture")
        if resolved then
            append_resolved(resolved, alpha_bleed, "preflight")
        end
    end

    local parts = type(parsed_map) == "table" and parsed_map.parsed_parts or nil
    for part_index = 1, #(parts or {}) do
        local part = parts[part_index] or {}
        for texture_index = 1, #(part.face_textures or {}) do
            local face_texture = part.face_textures[texture_index]
            local alpha_safe
            if RBX._face_texture_needs_alpha_safe_sampling then
                alpha_safe = RBX._face_texture_needs_alpha_safe_sampling(
                    face_texture)
            else
                alpha_safe = type(face_texture) == "table"
                    and (face_texture.class_name == "Decal"
                        or face_texture.class_name == "Texture")
            end
            append_reference(face_texture and face_texture.texture, alpha_safe)
        end
        local surface = part.surface_appearance
        if type(surface) == "table" then
            append_reference(surface.color_map, parsed_surface_alpha_bleed(surface))
            append_reference(surface.normal_map, false)
            append_reference(surface.roughness_map, false)
            append_reference(surface.metalness_map, false)
            append_reference(surface.emissive_mask, false)
        end
    end

    local ok_manifest, contents = pcall(
        love.filesystem.read, self:_texture_manifest_file(map_path))
    if ok_manifest and type(contents) == "string" then
        for line in contents:gmatch("[^\n]+") do
            local path, alpha_bleed = parse_texture_manifest_line(line)
            append_resolved(path, alpha_bleed, "manifest")
        end
    end
    if #jobs == 0 then return end

    self._texture_prefetch_stats.queued_jobs = #jobs
    self._texture_prefetch_stats.source_bytes = source_bytes
    self._texture_prefetch_seq = (self._texture_prefetch_seq or 0) + 1
    local req_name = "rbx_texprefetch_req_" .. self._texture_prefetch_seq
    local res_name = "rbx_texprefetch_res_" .. self._texture_prefetch_seq
    self._texture_prefetch_req = love.thread.getChannel(req_name)
    self._texture_prefetch_res = love.thread.getChannel(res_name)
    self._texture_prefetch_threads = {}
    local processor_count
    if love.system and type(love.system.getProcessorCount) == "function" then
        local ok_count, count = pcall(love.system.getProcessorCount)
        if ok_count then processor_count = count end
    end
    local worker_count = math.min(
        texture_prefetch_worker_limit(processor_count), #jobs)
    for _ = 1, worker_count do
        local ok_thread, thread = pcall(
            love.thread.newThread,
            require("engine/root") .. "/graphics/rbx/texture_decode_thread.lua")
        if ok_thread and thread then
            local started = pcall(function()
                thread:start(req_name, res_name)
            end)
            if started then
                self._texture_prefetch_threads[
                    #self._texture_prefetch_threads + 1] = thread
            end
        end
    end
    local live_workers = #self._texture_prefetch_threads
    self._texture_prefetch_cache_budget_bytes = math.max(0,
        TEX_PREFETCH_MAX_RESIDENT_BYTES
            - live_workers * TEX_PREFETCH_MAX_DECODED_IMAGE_BYTES)
    self._texture_prefetch_stats.resident_budget_bytes =
        TEX_PREFETCH_MAX_RESIDENT_BYTES
    self._texture_prefetch_pending_jobs = jobs
    self._texture_prefetch_next_job = 1
    self._texture_prefetch_inflight = 0
    dispatch_texture_prefetch_jobs(self, live_workers)
end

-- non-blocking: move any completed worker decodes into the prefetch cache. called lazily
-- from _get_or_load_texture, so decodes accumulate while classify runs
function RBX:_drain_texture_prefetch()
    local res = self._texture_prefetch_res
    local cache = self._prefetched_image_data
    if not res or not cache then return end
    while true do
        local msg = res:pop()
        if msg == nil then break end
        self._texture_prefetch_inflight = math.max(0,
            (tonumber(self._texture_prefetch_inflight) or 0) - 1)
        if type(msg) == "table" and type(msg.path) == "string" then
            local stats = self._texture_prefetch_stats
            if stats then
                stats.completed_jobs = stats.completed_jobs + 1
                stats.worker_decode_seconds = stats.worker_decode_seconds
                    + math.max(0, tonumber(msg.decode_seconds) or 0)
                stats.worker_alpha_bleed_seconds =
                    stats.worker_alpha_bleed_seconds
                    + math.max(0, tonumber(msg.alpha_bleed_seconds) or 0)
            end
            if msg.data then
                local key = texture_prefetch_role_key(
                    msg.path, msg.alpha_bleed == true)
                store_texture_prefetch_image(
                    self, key, msg.data, msg.bled == true,
                    msg.decoded_bytes, true)
            elseif stats then
                stats.failed_jobs = stats.failed_jobs + 1
            end
        end
        -- one completed result creates room for exactly one replacement. Thus
        -- response/in-flight ImageData can never grow with total queue length
        dispatch_texture_prefetch_jobs(self, 1)
    end
end

-- end of load: stop workers, release any unconsumed ImageData, and persist the manifest of
-- resolved texture paths actually requested this boot (so the next boot can prefetch them)
function RBX:_stop_texture_prefetch(map_path, persist_manifest)
    self._texture_prefetch_stopping = true
    self._texture_prefetch_pending_jobs = nil
    local req = self._texture_prefetch_req
    local res = self._texture_prefetch_res
    local threads = self._texture_prefetch_threads or {}
    if req then
        -- STOP must not sit behind an entire map's remaining FIFO. Discard work
        -- the completed load no longer needs, then give every worker one token
        if req.clear then
            pcall(req.clear, req)
        end
        for _ = 1, #threads do
            pcall(function() req:push(TEX_PREFETCH_STOP) end)
        end
    end
    for index = 1, #threads do
        local thread = threads[index]
        if thread and thread.wait then
            pcall(thread.wait, thread)
        end
    end
    -- workers are now quiescent, so this final drain cannot race a late ImageData
    -- push after the cache has been discarded
    self:_drain_texture_prefetch()
    if self._prefetched_image_data then
        for _, entry in pairs(self._prefetched_image_data) do
            if type(entry) == "table" and entry.data ~= nil then
                release_texture_prefetch_entry(self, entry)
            elseif entry then
                pcall(entry.release, entry)
            end
        end
    end
    if req and req.clear then
        pcall(req.clear, req)
    end
    if res and res.clear then
        pcall(res.clear, res)
    end
    for index = 1, #threads do
        local thread = threads[index]
        if thread and thread.release then
            pcall(thread.release, thread)
        end
    end
    self._prefetched_image_data = nil
    self._texture_prefetch_req = nil
    self._texture_prefetch_res = nil
    self._texture_prefetch_threads = nil
    self._texture_prefetch_next_job = nil
    self._texture_prefetch_inflight = 0
    self._texture_prefetch_cached_bytes = 0
    self._texture_prefetch_cache_budget_bytes = nil

    if persist_manifest ~= false
        and love and love.filesystem
        and self._texture_manifest_paths and next(self._texture_manifest_paths) then
        local list = {}
        for index = 1, #(self._texture_manifest_order or {}) do
            local key = self._texture_manifest_order[index]
            local entry = self._texture_manifest_paths[key]
            if entry then
                list[#list + 1] = (entry.alpha_bleed and "B\t" or "N\t")
                    .. entry.path
            end
        end
        pcall(love.filesystem.createDirectory, "texture_manifest")
        pcall(love.filesystem.write, self:_texture_manifest_file(map_path), table.concat(list, "\n"))
    end
    self._texture_manifest_paths = nil
    self._texture_manifest_order = nil
end

local function renderer_texture_placeholder(renderer, kind)
    if kind == "transparent" then
        return renderer._transparent_texture or renderer._white_texture,
            "__transparent"
    end
    if kind == "flat_normal" then
        return renderer._flat_normal_texture or renderer._white_texture,
            "__flat_normal"
    end
    if kind == "roughness_half" then
        return renderer._roughness_half_texture or renderer._white_texture,
            "__roughness_half"
    end
    if kind == "black" then
        return renderer._black_texture or renderer._white_texture,
            "__black"
    end
    return renderer._white_texture, "__white"
end

function RBX:_get_or_load_texture(asset_path, wrap_mode)
    local options = nil
    if type(wrap_mode) == "table" then
        options = wrap_mode
        wrap_mode = options.wrap_mode
    end
    options = options or {}
    wrap_mode = wrap_mode == "repeat" and "repeat" or "clamp"
    local gui_placeholder = options.gui_placeholder == true
    local defer_remote_gpu_upload = options.defer_remote_gpu_upload == true
        or options.defer_gpu_upload == true

    local alpha_bleed = options.alpha_bleed == true
    -- Requested only by the static opaque-alpha candidate. the proof is made
    -- from the decoded local source, unavailable/remote paths remain false
    local classify_opaque_alpha = options.classify_opaque_alpha == true
    local use_mipmaps = options.mipmaps ~= false
    local min_filter = options.min_filter or options.texture_min_filter or self.texture_min_filter
    min_filter = min_filter == "nearest" and "nearest" or "linear"
    local mag_filter = options.mag_filter or options.texture_mag_filter or self.texture_mag_filter
    mag_filter = mag_filter == "nearest" and "nearest" or "linear"
    local mip_filter = options.mipmap_filter or options.mip_filter or self.texture_mipmap_filter or "linear"
    mip_filter = mip_filter == "none" and "none" or (mip_filter == "nearest" and "nearest" or "linear")
    local anisotropy = clamp(tonumber(options.anisotropy or options.texture_anisotropy or self.texture_anisotropy) or 1, 1, 16)
    local color_space = tostring(options.color_space or "srgb_color")
    local remote_pending_placeholder = options.remote_pending_placeholder
    if remote_pending_placeholder ~= "transparent"
        and remote_pending_placeholder ~= "flat_normal"
        and remote_pending_placeholder ~= "roughness_half"
        and remote_pending_placeholder ~= "black" then
        remote_pending_placeholder = "white"
    end
    local missing_placeholder, missing_placeholder_key =
        renderer_texture_placeholder(self, remote_pending_placeholder)
    if type(asset_path) ~= "string" or trim(asset_path) == "" then
        return missing_placeholder, missing_placeholder_key
    end
    local asset_cache_key = self:_renderer_asset_cache_key(asset_path, "texture")
    local cache_key = asset_cache_key .. "|" .. wrap_mode
        .. "|ab:" .. (alpha_bleed and "1" or "0")
        .. "|mm:" .. (use_mipmaps and "1" or "0")
        .. "|min:" .. min_filter
        .. "|mag:" .. mag_filter
        .. "|mip:" .. mip_filter
        .. "|aniso:" .. string.format("%.2f", anisotropy)
        .. "|cs:" .. color_space
        .. (gui_placeholder and "|gui:1" or "")
        .. "|rp:" .. remote_pending_placeholder
    local eligible_remote_id = self.allow_remote_asset_fetch == true
        and RemoteTexture.extract_asset_id(asset_path) or nil
    local sampler_resource_key = RBX._texture_sampler_resource_key(cache_key)
    local existing_remote_handle = self._remote_texture_manager
        and self._remote_texture_manager.sampler_handles[cache_key] or nil
    local cached = self._texture_cache[cache_key]
    if cached then
        self:_note_load_cache_stat("texture_cache_hits")
        if self._texture_cache_missing and self._texture_cache_missing[cache_key] then
            -- a renderer may opt in after a prior local-only lookup.  Eligible
            -- sources must pass through the finite remote state machine rather
            -- than replaying a permanent local negative cache entry
            if eligible_remote_id then
                self._texture_cache[cache_key] = nil
                self._texture_cache_missing[cache_key] = nil
                if self._texture_cache_resolved then
                    self._texture_cache_resolved[cache_key] = nil
                end
            elseif gui_placeholder then
                return note_gui_placeholder(self, asset_path)
            else
                return cached, missing_placeholder_key
            end
        else
            if self._texture_manifest_paths and not options.generated_surface_consumer then
                record_texture_manifest_demand(self,
                    self._texture_cache_resolved
                        and self._texture_cache_resolved[cache_key], alpha_bleed)
            end
            return cached, sampler_resource_key, existing_remote_handle
        end
    end
    self:_note_load_cache_stat("texture_cache_misses")

    local path_resolve_start = love.timer.getTime()
    local resolved = self:_resolve_asset_path(asset_path, "texture")
    self:_add_load_stage_time(
        "texture_path_resolve", love.timer.getTime() - path_resolve_start)
    local remote_handle = existing_remote_handle
    if not resolved and eligible_remote_id then
        local manager = self:_get_remote_texture_manager()
        local source
        source, remote_handle = manager:request(asset_path, cache_key, {
            wrap_mode = wrap_mode,
            alpha_bleed = alpha_bleed,
            mipmaps = use_mipmaps,
            min_filter = min_filter,
            mag_filter = mag_filter,
            mipmap_filter = mip_filter,
            anisotropy = anisotropy,
            color_space = color_space,
            placeholder_kind = remote_pending_placeholder,
            remote_pending_placeholder = remote_pending_placeholder,
            gui_placeholder = gui_placeholder,
        })
        if source and source.status == "ready" then
            if defer_remote_gpu_upload and remote_handle then
                self:_enqueue_remote_texture_promotion(remote_handle)
                local placeholder = remote_handle.texture
                    or missing_placeholder
                local pending_key = remote_handle.resource_key
                    or manager:pending_resource_key(remote_handle)
                remote_handle.texture = placeholder
                remote_handle.resource_key = pending_key
                return placeholder, pending_key, remote_handle
            end
            resolved = source.cache_path
        elseif remote_handle then
            local placeholder = missing_placeholder
            local pending_key = manager:pending_resource_key(remote_handle)
            remote_handle.texture = placeholder
            remote_handle.resource_key = pending_key
            return placeholder, pending_key, remote_handle
        end
    end
    if not resolved then
        self._texture_cache[cache_key] = missing_placeholder
        self._texture_cache_missing = self._texture_cache_missing or {}
        self._texture_cache_missing[cache_key] = true
        if gui_placeholder then
            return note_gui_placeholder(self, asset_path)
        end
        return missing_placeholder, missing_placeholder_key, remote_handle
    end

    local ok, image = false, nil
    local source_alpha_opaque = nil
    local function classify_source_alpha(image_data)
        if not classify_opaque_alpha or not image_data then return nil end
        local classified, opaque = pcall(
            RBX._alpha_bleed.is_fully_opaque, image_data)
        return classified and opaque == true or false
    end
    -- gamma-correct mode: color textures sample as srgb (linear=false), data maps like
    -- normals/roughness/metalness must bypass srgb decode (linear=true)
    local treat_as_linear = color_space ~= "srgb_color"

    -- record the exact source role for the next load and consume the matching
    -- worker result. Alpha-bled RGB must never satisfy an ordinary/data sampler
    if not options.generated_surface_consumer then
        record_texture_manifest_demand(self, resolved, alpha_bleed)
    end
    local source_role_key = texture_prefetch_role_key(resolved, alpha_bleed)
    local prefetched_entry
    if self._prefetched_image_data then
        self:_drain_texture_prefetch()
        prefetched_entry = self._prefetched_image_data[source_role_key]
    end
    local prefetched = prefetched_entry and prefetched_entry.data
    if prefetched then
        local prefetched_alpha_opaque = classify_source_alpha(prefetched)
        -- a legacy/decode-only producer can still feed this branch. preserve
        -- the synchronous exact fallback when it did not perform the bleed
        if alpha_bleed and prefetched_entry.bled ~= true then
            local bleed_start = love.timer.getTime()
            RBX._bleed_image_data_alpha(prefetched)
            self:_add_load_stage_time(
                "texture_alpha_bleed", love.timer.getTime() - bleed_start)
            prefetched_entry.bled = true
        end
        local upload_start = love.timer.getTime()
        ok, image = pcall(love.graphics.newImage, prefetched, {
            mipmaps = use_mipmaps,
            linear = treat_as_linear,
        })
        if not ok or not image then
            ok, image = pcall(love.graphics.newImage, prefetched)
        end
        self:_add_load_stage_time(
            "gpu_texture_upload", love.timer.getTime() - upload_start)
        local prefetch_stats = self._texture_prefetch_stats
        if ok and image then
            source_alpha_opaque = prefetched_alpha_opaque
        end
        if ok and image and prefetch_stats then
            local field = alpha_bleed and "alpha_bleed_hits" or "decode_hits"
            prefetch_stats[field] = prefetch_stats[field] + 1
        end
    end

    if not ok or not image then
        local decode_start = love.timer.getTime()
        local data_ok, image_data = pcall(love.image.newImageData, resolved)
        self:_add_load_stage_time("texture_decode", love.timer.getTime() - decode_start)
        if data_ok and image_data then
            local decoded_alpha_opaque = classify_source_alpha(image_data)
            if alpha_bleed then
                local bleed_start = love.timer.getTime()
                RBX._bleed_image_data_alpha(image_data)
                self:_add_load_stage_time(
                    "texture_alpha_bleed", love.timer.getTime() - bleed_start)
            end
            -- reuse one decoded/bled source across every sampler variant during
            -- this load when it fits the same aggregate resident budget as
            -- worker results. Oversized sources stay call-owned and are released
            -- immediately after the upload attempt
            local source_cache_entry
            if self._prefetched_image_data then
                local _
                _, source_cache_entry = store_texture_prefetch_image(
                    self, source_role_key, image_data, alpha_bleed,
                    nil, false)
            end
            local upload_start = love.timer.getTime()
            ok, image = pcall(love.graphics.newImage, image_data, { mipmaps = use_mipmaps, linear = treat_as_linear })
            if not ok or not image then
                ok, image = pcall(love.graphics.newImage, image_data)
            end
            self:_add_load_stage_time("gpu_texture_upload", love.timer.getTime() - upload_start)
            if ok and image then
                source_alpha_opaque = decoded_alpha_opaque
            end
            if source_cache_entry and source_cache_entry.accounted ~= true then
                release_texture_prefetch_entry(self, source_cache_entry)
            elseif not source_cache_entry then
                pcall(image_data.release, image_data)
            end
        end
    end
    if not ok or not image then
        -- path-based fallback for compressed/other formats newImageData can't decode
        local upload_start = love.timer.getTime()
        ok, image = pcall(love.graphics.newImage, resolved, { mipmaps = use_mipmaps, linear = treat_as_linear })
        self:_add_load_stage_time("gpu_texture_upload", love.timer.getTime() - upload_start)
    end
    if not ok or not image then
        local upload_start = love.timer.getTime()
        ok, image = pcall(love.graphics.newImage, resolved)
        self:_add_load_stage_time("gpu_texture_upload", love.timer.getTime() - upload_start)
    end
    if not ok or not image then
        self._texture_cache[cache_key] = missing_placeholder
        self._texture_cache_missing = self._texture_cache_missing or {}
        self._texture_cache_missing[cache_key] = true
        if gui_placeholder then
            return note_gui_placeholder(self, asset_path)
        end
        return missing_placeholder, missing_placeholder_key, remote_handle
    end
    if gui_placeholder then
        self._gui_image_resolved_count = (self._gui_image_resolved_count or 0) + 1
    end

    local set_filter_ok = pcall(image.setFilter, image, min_filter, mag_filter, anisotropy)
    if not set_filter_ok then
        image:setFilter(min_filter, mag_filter)
    end
    if image.setMipmapFilter then
        if mip_filter == "none" then
            pcall(image.setMipmapFilter, image, nil)
        else
            pcall(image.setMipmapFilter, image, mip_filter, tonumber(self.texture_mipmap_sharpness) or 0)
        end
    end
    image:setWrap(wrap_mode, wrap_mode)
    if classify_opaque_alpha then
        self._texture_alpha_opaque_by_image =
            self._texture_alpha_opaque_by_image
            or setmetatable({}, { __mode = "k" })
        self._texture_alpha_opaque_by_image[image] =
            source_alpha_opaque == true
    end
    self._texture_cache[cache_key] = image
    self._texture_cache_resolved = self._texture_cache_resolved or {}
    self._texture_cache_resolved[cache_key] = resolved
    self._texture_sampler_debug_by_texture = self._texture_sampler_debug_by_texture or setmetatable({}, { __mode = "k" })
    self._texture_sampler_debug_by_texture[image] = {
        asset_path = asset_path,
        resolved = resolved,
        wrap_mode = wrap_mode,
        min_filter = min_filter,
        mag_filter = mag_filter,
        mipmap_filter = mip_filter,
        mipmaps = use_mipmaps == true,
        anisotropy = anisotropy,
        color_space = color_space,
        alpha_bleed = alpha_bleed == true,
        alpha_opaque = source_alpha_opaque == true,
    }
    if self._texture_cache_missing then
        self._texture_cache_missing[cache_key] = nil
    end
    if remote_handle then
        remote_handle.texture = image
        remote_handle.resource_key = sampler_resource_key
        remote_handle.stable_resource_key = sampler_resource_key
        remote_handle.resolved_path = resolved
        remote_handle.resolved_debug_path = resolved
        remote_handle.content_revision =
            tonumber(remote_handle.source and remote_handle.source.revision)
                or tonumber(remote_handle.revision) or 0
        remote_handle.materialized = true
        remote_handle.state = "ready"
        remote_handle.pending = false
        remote_handle.ready = true
    end
    self:_note_load_cache_stat("gpu_texture_upload_count")
    self._texture_uploads_total = (self._texture_uploads_total or 0) + 1
    if self._note_gpu_upload_bytes and image.getDimensions then
        local ok_dim, width, height = pcall(image.getDimensions, image)
        if ok_dim and width and height then
            local mip_factor = use_mipmaps and 4 / 3 or 1
            self:_note_gpu_upload_bytes(width * height * 4 * mip_factor)
        end
    end
    return image, sampler_resource_key, remote_handle
end

function RBX:_get_texture_sampler_debug(texture)
    local metadata = self._texture_sampler_debug_by_texture and self._texture_sampler_debug_by_texture[texture] or nil
    if type(metadata) ~= "table" then
        return nil
    end
    local copy = {}
    for key, value in pairs(metadata) do
        copy[key] = value
    end
    return copy
end

function RBX:_texture_has_opaque_alpha(texture)
    return self._texture_alpha_opaque_by_image ~= nil
        and self._texture_alpha_opaque_by_image[texture] == true
end

function RBX:_get_or_parse_mesh(mesh_path, asset_type, consumer)
    if type(mesh_path) ~= "string" or trim(mesh_path) == "" then
        self:_unbind_remote_mesh_consumer(consumer)
        return nil
    end

    asset_type = asset_type or "mesh"
    local asset_id = extract_asset_id(mesh_path)
    local local_mesh = self:_get_or_parse_local_mesh(mesh_path, asset_type)
    if local_mesh then
        self:_unbind_remote_mesh_consumer(consumer)
        return local_mesh
    end

    if self.allow_remote_mesh_fetch ~= true
        or not asset_id or (asset_type ~= "mesh" and asset_type ~= "csg_mesh") then
        self:_unbind_remote_mesh_consumer(consumer)
        return nil
    end

    local is_union = asset_type == "csg_mesh"
    local manager = self:_get_remote_mesh_manager()
    local policy = RBX._accurate_face_axes == true
        and "render_accurate_axes" or "render"
    local previous = type(consumer) == "table"
        and rawget(consumer, "_remote_mesh_handle") or nil
    local asset_context = {
        map_path = self._map_build_path or self.map_path or RBX._last_parsed_map_path,
        asset_root = self.asset_root,
    }
    local desired_variant_key = RemoteMesh.variant_key(
        asset_id, asset_type, policy, asset_context)
    if previous and previous.variant_key ~= desired_variant_key then
        -- the authored source has already changed, so the previous binding is
        -- stale even if admission of the replacement fails. release it before
        -- the capped request: otherwise that same stale consumer can pin the
        -- only evictable source/variant and leave itself on fallback forever
        if type(manager.unbind) == "function" then
            manager:unbind(previous, consumer)
        end
        rawset(consumer, "_remote_mesh_handle", nil)
        rawset(consumer, "_remote_mesh_variant_key", nil)
        previous = nil
    end
    local handle = manager:request(asset_id, asset_type, policy, consumer, {
        part_id = type(consumer) == "table" and consumer._id or nil,
    }, asset_context)
    if not handle then
        self:_unbind_remote_mesh_consumer(consumer)
        return nil
    end

    if type(consumer) == "table" then
        previous = previous or rawget(consumer, "_remote_mesh_handle")
        if previous and previous ~= handle and type(manager.unbind) == "function" then
            manager:unbind(previous, consumer)
        end
        rawset(consumer, "_remote_mesh_handle", handle)
        rawset(consumer, "_remote_mesh_variant_key", handle.variant_key)
    end

    if handle._renderer_cache_seen then
        self:_note_load_cache_stat(is_union and "union_cache_hits" or "mesh_cache_hits")
        if handle.ready and handle.result then
            self.reused_mesh_count = (self.reused_mesh_count or 0) + 1
        end
    else
        handle._renderer_cache_seen = true
        self:_note_load_cache_stat(is_union and "union_cache_misses" or "mesh_cache_misses")
    end
    -- pending and finite-negative states intentionally remain absent from the
    -- ordinary mesh cache. a later worker publication must be observable
    local result = handle.ready == true and handle.result or nil
    local observed = self._remote_mesh_full_build_seen
    if result ~= nil and type(observed) == "table"
        and type(consumer) == "table" then
        local slot = type(handle.consumer_slots) == "table"
            and handle.consumer_slots[consumer] or nil
        local bind_revision = slot ~= nil
            and type(handle.consumer_bind_revision) == "table"
            and handle.consumer_bind_revision[slot] or nil
        observed[consumer] = {
            handle = handle,
            slot = slot,
            bind_revision = bind_revision,
            revision = tonumber(handle.revision) or 0,
        }
    end
    return result
end

part_has_embedded_mesh_payload = function(part)
    if type(part) ~= "table" then
        return false
    end
    if type(part.EmbeddedMeshData) == "string" and part.EmbeddedMeshData ~= "" then
        return true
    end
    return type(part.EmbeddedMeshDataCandidates) == "table" and #part.EmbeddedMeshDataCandidates > 0
end

local function part_has_explicit_mesh_id(part)
    if type(part) ~= "table"
        or type(part.MeshId) ~= "string"
        or trim(part.MeshId) == "" then
        return false
    end
    -- MeshId is an active geometry source only for SpecialMesh.FileMesh
    -- Native Studio deserializes missing/malformed/out-of-range MeshType as
    -- Head even when a MeshId property is present, Head ignores that dormant
    -- property and uses the built-in Head asset. Passing MeshId back into the
    -- normalizer here used to re-infer FileMesh and undo the parser's native
    -- default immediately before draw submission
    if part.MeshOwner == "SpecialMesh" then
        return normalize_special_mesh_type(part.SpecialMeshType, nil)
            == "FileMesh"
    end
    return true
end

function RBX._get_default_part_mesh_asset_path(part)
    if type(part) ~= "table" then
        return nil
    end
    if part_has_explicit_mesh_id(part) then
        return nil
    end
    if part.MeshOwner ~= "SpecialMesh" then
        return nil
    end
    if normalize_special_mesh_type(part.SpecialMeshType, part.MeshId) == "Head" then
        return RBX.DEFAULT_HEAD_MESH_ASSET
    end
    return nil
end

function RBX._part_has_renderable_mesh_source(part)
    if type(part) ~= "table" then
        return false
    end
    return part_has_explicit_mesh_id(part)
        or part_has_embedded_mesh_payload(part)
        or RBX._get_default_part_mesh_asset_path(part) ~= nil
end

get_part_embedded_mesh_candidates = function(part)
    if type(part) ~= "table" or not part_has_embedded_mesh_payload(part) then
        return nil
    end

    local primary = part.EmbeddedMeshData
    local extra = part.EmbeddedMeshDataCandidates
    local primary_present = type(primary) == "string" and primary ~= ""

    -- parsed maps already carry a non-empty, ordered, duplicate-free candidate
    -- list and mirror its first value into EmbeddedMeshData. That list is
    -- read-only here, so borrow it instead of allocating candidates+seen for
    -- every first bounds/material lookup. Runtime-authored or mutated tables
    -- are revalidated and fall through to the original defensive builder
    if type(extra) == "table" and #extra > 0
        and (not primary_present or primary == extra[1]) then
        local canonical = true
        for i = 1, #extra do
            local candidate = extra[i]
            if type(candidate) ~= "string" or candidate == "" then
                canonical = false
                break
            end
            for j = 1, i - 1 do
                if extra[j] == candidate then
                    canonical = false
                    break
                end
            end
            if not canonical then break end
        end
        if canonical then
            return extra
        end
    end

    local candidates = {}
    local seen = {}
    append_unique_string_candidate(candidates, seen, primary)

    if type(extra) == "table" then
        for i = 1, #extra do
            append_unique_string_candidate(candidates, seen, extra[i])
        end
    end

    return #candidates > 0 and candidates or nil
end
RBX._get_part_embedded_mesh_candidates =
    get_part_embedded_mesh_candidates

-- a union rendered from CSGPHS is showing its COLLISION geometry: these files carry
-- no CSGMDL render mesh at all (docs/CSGPHS-FORMAT.md). record that per part exactly
-- once -- never per frame -- so the approximation is visible without spamming the
-- console, and keep a structured tally the caller can inspect
local CSG_APPROX_PRINT_LIMIT = 3

function RBX:_note_csg_approximation(part, parsed)
    part._csg_approx_noted = true
    local report = self._csg_approximation_report
    if not report then
        report = { part_count = 0, by_kind = {}, samples = {} }
        self._csg_approximation_report = report
    end
    local kind = parsed.csg_approximation or "approximation"
    report.part_count = report.part_count + 1
    report.by_kind[kind] = (report.by_kind[kind] or 0) + 1
    if #report.samples < CSG_APPROX_PRINT_LIMIT then
        report.samples[#report.samples + 1] = {
            name = tostring(part.Name or part.ClassName or "?"),
            kind = kind,
            hull_count = parsed.csg_hull_count,
            source_vertex_count = parsed.csg_source_vertex_count,
        }
        print(string.format(
            "[rbx] union '%s' uses an approximation (%s, %s hulls), no render mesh is stored in the file",
            report.samples[#report.samples].name, kind, tostring(parsed.csg_hull_count)))
    elseif report.part_count == CSG_APPROX_PRINT_LIMIT + 1 then
        print("[rbx] more unions use approximations; "
            .. "read renderer._csg_approximation_report for the tally")
    end
end

---cache key for a set of embedded payload candidates
---
---for the overwhelmingly common single-candidate case the key IS the payload string
---That costs nothing: LuaJIT interns strings, so 1,018 unions carrying byte-identical
---PhysicalConfigData already share ONE string object, and using it as a table key
---retains no bytes that the parts were not retaining anyway. a digest would add a
---hash pass over every payload and a collision class for no benefit
function RBX._embedded_mesh_content_key(candidates)
    if #candidates == 1 then
        return candidates[1], false
    end

    -- Roblox payloads are arbitrary binary strings and may contain every byte,
    -- including NUL. a delimiter join therefore aliases distinct candidate
    -- boundaries (for example {"a\0b","c"} and {"a","b\0c"}). Multi-
    -- candidate keys live in a controller namespace separate from the common
    -- single-payload keys, and length framing makes the ordered set injective
    -- without copying the overwhelmingly common single payload
    local framed = { tostring(#candidates), ":" }
    for index = 1, #candidates do
        local candidate = candidates[index]
        framed[#framed + 1] = tostring(#candidate)
        framed[#framed + 1] = ":"
        framed[#framed + 1] = candidate
    end
    return table.concat(framed), true
end

---two direct value tables rather than one prefixed key, so a single-candidate
---key stays the payload string itself with no second allocation.  one combined
---controller budgets both tables: otherwise ordinary meshes and CSG could each
---consume a full independent ceiling
function RBX:_embedded_mesh_content_cache(is_csg)
    local field = is_csg and "_embedded_csg_mesh_by_content" or "_embedded_mesh_by_content"
    local cache = self[field]
    if type(cache) ~= "table" then
        cache = {}
        self[field] = cache
    end
    return cache
end

function RBX:_embedded_mesh_content_cache_controller()
    local mesh_values = self:_embedded_mesh_content_cache(false)
    local csg_values = self:_embedded_mesh_content_cache(true)
    local controller = self._embedded_mesh_content_cache_budget
    if not controller or not controller:is_bound_to(mesh_values, csg_values) then
        controller = EmbeddedMeshCache.new(mesh_values, csg_values, {
            max_bytes = self.embedded_mesh_cache_max_bytes,
            max_entries = self.embedded_mesh_cache_max_entries,
        })
        self._embedded_mesh_content_cache_budget = controller
    end
    return controller
end

---a smaller budget evicts unpinned entries while live bindings keep their meshes
function RBX:configure_embedded_mesh_cache(options)
    options = type(options) == "table" and options or {}
    if options.max_bytes ~= nil then
        self.embedded_mesh_cache_max_bytes = options.max_bytes
    elseif options.max_megabytes ~= nil then
        self.embedded_mesh_cache_max_bytes =
            (tonumber(options.max_megabytes) or 0) * 1024 * 1024
    end
    if options.max_entries ~= nil then
        self.embedded_mesh_cache_max_entries = options.max_entries
    end
    local controller = self:_embedded_mesh_content_cache_controller()
    controller:reconfigure({
        max_bytes = self.embedded_mesh_cache_max_bytes,
        max_entries = self.embedded_mesh_cache_max_entries,
    })
    return controller:snapshot()
end

function RBX:get_embedded_mesh_cache_stats()
    return self:_embedded_mesh_content_cache_controller():snapshot()
end

function RBX:_release_part_embedded_mesh_cache(part)
    if type(part) ~= "table" then return false end
    local released = false
    if rawget(part, "_embedded_mesh_cache_bound") == true then
        local controller = self._embedded_mesh_content_cache_budget
        if controller then
            released = controller:unpin(
                rawget(part, "_embedded_mesh_cache_is_csg") == true,
                rawget(part, "_embedded_mesh_cache_key"),
                rawget(part, "_embedded_mesh_cache_generation"),
                rawget(part, "_embedded_mesh_cache_is_multi") == true)
        end
    end
    rawset(part, "_embedded_mesh_cache_bound", nil)
    rawset(part, "_embedded_mesh_cache_is_csg", nil)
    rawset(part, "_embedded_mesh_cache_key", nil)
    rawset(part, "_embedded_mesh_cache_generation", nil)
    rawset(part, "_embedded_mesh_cache_is_multi", nil)
    -- this is the strong lifetime edge that used to keep decoded geometry from
    -- every previous map alive through externally retained destroyed facades
    rawset(part, "_embedded_mesh_cache", nil)
    return released
end

function RBX:_bind_part_embedded_mesh_cache(
        part, is_csg, content_key, content_key_is_multi, mesh, admitted)
    self:_release_part_embedded_mesh_cache(part)
    rawset(part, "_embedded_mesh_cache", mesh)

    local controller = self:_embedded_mesh_content_cache_controller()
    if admitted and controller:pin(
            is_csg, content_key, controller.generation, content_key_is_multi) then
        rawset(part, "_embedded_mesh_cache_bound", true)
        rawset(part, "_embedded_mesh_cache_is_csg", is_csg and true or false)
        rawset(part, "_embedded_mesh_cache_key", content_key)
        rawset(part, "_embedded_mesh_cache_generation", controller.generation)
        rawset(part, "_embedded_mesh_cache_is_multi",
            content_key_is_multi and true or false)
    else
        -- the part memo remains authoritative and safe.  this only means a
        -- later part may have to decode the same content again
        controller:note_untracked_binding()
    end
    return mesh
end

function RBX:_clear_embedded_mesh_content_cache()
    local controller = self._embedded_mesh_content_cache_budget
    if controller then
        controller:clear()
        return true
    end
    local mesh_values = self._embedded_mesh_by_content
    local csg_values = self._embedded_csg_mesh_by_content
    if type(mesh_values) == "table" then
        for key in pairs(mesh_values) do mesh_values[key] = nil end
    end
    if type(csg_values) == "table" then
        for key in pairs(csg_values) do csg_values[key] = nil end
    end
    return false
end

---retire one loaded map without discarding immutable decoded content shared by
---a later map/reload. `_reset_runtime_parts` has already severed per-part memos
---and released every pin. the controller validates that invariant and falls
---back to a full clear if any old-map ownership remains
function RBX:_retire_embedded_mesh_content_cache_generation()
    local controller = self._embedded_mesh_content_cache_budget
    if controller then
        return controller:retire_generation()
    end
    return true
end

-- a full scene build asks for the same local mesh through several independent
-- correctness routes: contact-AO bounds, SurfaceAppearance classification,
-- repeated-mesh bucketing, baked submission, and face decals.  the decoded
-- asset caches remain the long-lived authority, this memo only carries a
-- positive result across those calls inside one full build
--
-- Mesh values are weak deliberately.  a scene build must not bypass the
-- weighted local-mesh cache's resident-byte limit, and an interrupted build
-- must never become another per-Part lifetime owner of decoded geometry.  a
-- budget eviction or collection simply turns the next access into a normal
-- resolver miss
local function full_build_mesh_memo_metadata(part)
    local candidates = part and part.EmbeddedMeshDataCandidates or nil
    return {
        render_prop_revision = tonumber(part and part._render_prop_revision) or 0,
        class_name = part and part.ClassName,
        mesh_owner = part and part.MeshOwner,
        special_mesh_type = part and part.SpecialMeshType,
        mesh_id = part and part.MeshId,
        embedded_mesh_data = part and part.EmbeddedMeshData,
        embedded_candidates = candidates,
        embedded_candidate_count = type(candidates) == "table" and #candidates or -1,
        render_fidelity = part and part.RenderFidelity,
        mesh_lod_base_mesh = part and part._mesh_lod_base_mesh,
        mesh_lod_index = part and part._mesh_lod_index,
        mesh_lod_fidelity = part and part._mesh_lod_fidelity,
    }
end

local function full_build_mesh_memo_metadata_matches(metadata, part)
    if type(metadata) ~= "table" or type(part) ~= "table"
        or part._destroyed == true then
        return false
    end
    local candidates = part.EmbeddedMeshDataCandidates
    return metadata.render_prop_revision
            == (tonumber(part._render_prop_revision) or 0)
        and metadata.class_name == part.ClassName
        and metadata.mesh_owner == part.MeshOwner
        and metadata.special_mesh_type == part.SpecialMeshType
        and metadata.mesh_id == part.MeshId
        and metadata.embedded_mesh_data == part.EmbeddedMeshData
        and metadata.embedded_candidates == candidates
        and metadata.embedded_candidate_count
            == (type(candidates) == "table" and #candidates or -1)
        and metadata.render_fidelity == part.RenderFidelity
        and metadata.mesh_lod_base_mesh == part._mesh_lod_base_mesh
        and metadata.mesh_lod_index == part._mesh_lod_index
        and metadata.mesh_lod_fidelity == part._mesh_lod_fidelity
end

function RBX:_clear_full_build_mesh_resolution_memo(expected, reason)
    local memo = self._full_build_mesh_resolution_memo
    if expected ~= nil and memo ~= expected then
        return false
    end
    self._full_build_mesh_resolution_memo = nil
    if type(memo) == "table" then
        self._last_full_build_mesh_resolution_memo_stats = {
            token = memo.token,
            lookups = memo.lookups or 0,
            hits = memo.hits or 0,
            stores = memo.stores or 0,
            invalidations = memo.invalidations or 0,
            weak_misses = memo.weak_misses or 0,
            nil_bypasses = memo.nil_bypasses or 0,
            remote_bypasses = memo.remote_bypasses or 0,
            csg_override_bypasses = memo.csg_override_bypasses or 0,
            reason = reason or "cleared",
        }
        return true
    end
    return false
end

function RBX:_begin_full_build_mesh_resolution_memo()
    self:_clear_full_build_mesh_resolution_memo(nil, "superseded")
    local token = (tonumber(self._full_build_mesh_resolution_memo_token) or 0) + 1
    self._full_build_mesh_resolution_memo_token = token
    local memo = {
        token = token,
        -- both sides are weak: neither a retained old Part nor an evicted mesh
        -- can be kept alive by an abandoned build transaction
        values = setmetatable({}, { __mode = "kv" }),
        metadata = setmetatable({}, { __mode = "k" }),
        lookups = 0,
        hits = 0,
        stores = 0,
        invalidations = 0,
        weak_misses = 0,
        nil_bypasses = 0,
        remote_bypasses = 0,
        csg_override_bypasses = 0,
    }
    self._full_build_mesh_resolution_memo = memo
    return memo
end

function RBX:_get_or_parse_part_mesh(part)
    local memo = self._full_build_mesh_resolution_memo
    if type(memo) == "table" and type(part) == "table" then
        memo.lookups = (memo.lookups or 0) + 1
        local metadata = memo.metadata[part]
        if metadata ~= nil then
            if rawget(part, "_remote_mesh_handle") == nil
                and full_build_mesh_memo_metadata_matches(metadata, part) then
                local memoized = memo.values[part]
                if memoized ~= nil then
                    memo.hits = (memo.hits or 0) + 1
                    self.reused_mesh_count = (self.reused_mesh_count or 0) + 1
                    return memoized
                end
                -- the weak value was legitimately evicted/collected.  remove
                -- its metadata so the new authoritative result can be stored
                memo.weak_misses = (memo.weak_misses or 0) + 1
            else
                memo.invalidations = (memo.invalidations or 0) + 1
            end
            memo.values[part] = nil
            memo.metadata[part] = nil
        end
    end

    local parsed = self:_resolve_part_mesh(part)
    if not parsed then
        if type(memo) == "table" then
            memo.nil_bypasses = (memo.nil_bypasses or 0) + 1
        end
        clear_part_mesh_lod_state(part)
        return nil
    end
    if parsed and parsed.csg_approximated and not part._csg_approx_noted then
        self:_note_csg_approximation(part, parsed)
    end
    if parsed and self._select_mesh_render_lod then
        parsed = self:_select_mesh_render_lod(part, parsed)
    end

    if type(memo) == "table" and self._full_build_mesh_resolution_memo == memo then
        local remote_bound = rawget(part, "_remote_mesh_handle") ~= nil
        local csg_override = parsed.source_kind == "csg_physics"
            and is_csg_part_class(part.ClassName)
            and part_has_explicit_mesh_id(part)
        if remote_bound then
            -- pending, ready, and refreshed remote variants must be observed on
            -- every call so the full-build publication ledger stays exact
            memo.remote_bypasses = (memo.remote_bypasses or 0) + 1
        elseif csg_override then
            -- a collision-hull union is provisional whenever an explicit
            -- render MeshId exists, even when remote acquisition is disabled
            -- for this particular call/build
            memo.csg_override_bypasses =
                (memo.csg_override_bypasses or 0) + 1
        else
            memo.values[part] = parsed
            memo.metadata[part] = full_build_mesh_memo_metadata(part)
            memo.stores = (memo.stores or 0) + 1
        end
    end
    return parsed
end

function RBX:_resolve_part_mesh(part)
    if type(part) ~= "table" then
        return nil
    end

    local asset_type = is_csg_part_class(part.ClassName) and "csg_mesh" or "mesh"
    local has_mesh_id = part_has_explicit_mesh_id(part)
    local default_mesh_path = RBX._get_default_part_mesh_asset_path(part)

    if is_csg_part_class(part.ClassName) and has_mesh_id then
        local parsed_asset_mesh = self:_get_or_parse_local_mesh(part.MeshId, asset_type)
        if parsed_asset_mesh then
            self:_unbind_remote_mesh_consumer(part)
            return RBX._adjust_renderable_mesh_for_part_usage(parsed_asset_mesh, part)
        end
    end

    -- part._embedded_mesh_cache is a per-INSTANCE memo (one table read on the hot
    -- path). the authority behind it is the per-CONTENT cache below
    local cached = part._embedded_mesh_cache
    if cached ~= nil and cached ~= false then
        -- a collision-hull union is only a temporary visual fallback while its
        -- explicit remote render mesh is pending. Recheck the async handle on
        -- every scene build so the instance memo cannot permanently mask the
        -- eventual high-fidelity result
        if cached.source_kind == "csg_physics"
            and is_csg_part_class(part.ClassName) and has_mesh_id then
            local remote_override = self:_get_or_parse_mesh(
                part.MeshId, asset_type, part)
            if remote_override then
                return RBX._adjust_renderable_mesh_for_part_usage(
                    remote_override, part)
            end
        else
            self:_unbind_remote_mesh_consumer(part)
        end
        self.reused_mesh_count = (self.reused_mesh_count or 0) + 1
        return cached
    end

    if cached == nil then
        local embedded_mesh_candidates = get_part_embedded_mesh_candidates(part)
        if embedded_mesh_candidates then
            local is_csg = is_csg_part_class(part.ClassName)
            local content_key, content_key_is_multi =
                RBX._embedded_mesh_content_key(embedded_mesh_candidates)
            local decode_context = is_csg
                and self:_embedded_mesh_decode_context_key() or nil
            -- N unions built from the SAME payload now share one parse and one parsed
            -- table. Measured on the shipped maps (embedded payload occurrences vs
            -- distinct payloads): 2002 -> 212 in one test place (89.4% redundant), 169 -> 80
            -- and 85 -> 22 in others. Keyed per INSTANCE, the first place
            -- decoded 2002 payloads -- 1018 of them a zstd frame plus a convex hull --
            -- and retained 2002 full copies of 212 distinct meshes
            local content_cache = self:_embedded_mesh_content_cache_controller()
            local shared, cache_hit = content_cache:get(
                is_csg, content_key, content_key_is_multi, decode_context)
            local admitted = cache_hit
            if not cache_hit then
                local best_embedded_mesh = nil
                local best_embedded_score = -1
                for i = 1, #embedded_mesh_candidates do
                    local candidate = embedded_mesh_candidates[i]
                    local parsed = parse_renderable_mesh_data(candidate)
                    if is_csg
                        and RBX._get_renderable_mesh_score(parsed) < 4 then
                        parsed = RBX._choose_preferred_renderable_mesh(
                            parsed,
                            self:_extract_csg_childdata_mesh_from_asset(candidate)
                        )
                    end
                    if parsed then
                        local score = RBX._get_renderable_mesh_score(parsed)
                        if score > best_embedded_score then
                            best_embedded_mesh = parsed
                            best_embedded_score = score
                        end
                        if best_embedded_score >= 4 then
                            break
                        end
                    end
                end
                if best_embedded_mesh then
                    -- identity today, but it must run before the result is shared
                    best_embedded_mesh = RBX._adjust_renderable_mesh_for_part_usage(best_embedded_mesh, part)
                    self.unique_mesh_count = (self.unique_mesh_count or 0) + 1
                end
                shared = best_embedded_mesh or false
                admitted = content_cache:publish(
                    is_csg, content_key, shared, content_key_is_multi,
                    decode_context)
            elseif shared ~= false then
                self.reused_mesh_count = (self.reused_mesh_count or 0) + 1
            end

            if shared ~= false then
                -- the MeshId override depends on THIS part's MeshId, not on the payload
                -- bytes, so it is applied per part and deliberately not cached under the
                -- content key. Taking it also leaves the instance memo unset, exactly as
                -- before, so the override is re-evaluated on every call
                if shared.source_kind == "csg_physics" and is_csg and has_mesh_id then
                    local parsed_asset_mesh = self:_get_or_parse_mesh(
                        part.MeshId, asset_type, part)
                    if parsed_asset_mesh then
                        return RBX._adjust_renderable_mesh_for_part_usage(parsed_asset_mesh, part)
                    end
                else
                    self:_unbind_remote_mesh_consumer(part)
                end
                return self:_bind_part_embedded_mesh_cache(
                    part, is_csg, content_key, content_key_is_multi,
                    shared, admitted)
            end
            part._embedded_mesh_cache = false
        end
    end

    local mesh_source = has_mesh_id and part.MeshId or default_mesh_path
    return RBX._adjust_renderable_mesh_for_part_usage(
        self:_get_or_parse_mesh(mesh_source, asset_type, part),
        part
    )
end

function transform_local_bounds(px, py, pz,
                                      rx, ry, rz,
                                      ux, uy, uz,
                                      bx, by, bz,
                                      local_bounds,
                                      scale_x, scale_y, scale_z)
    local bounds = local_bounds or UNIT_PART_BOUNDS
    local xs = { (bounds.min_x or -0.5) * scale_x, (bounds.max_x or 0.5) * scale_x }
    local ys = { (bounds.min_y or -0.5) * scale_y, (bounds.max_y or 0.5) * scale_y }
    local zs = { (bounds.min_z or -0.5) * scale_z, (bounds.max_z or 0.5) * scale_z }

    local min_x, min_y, min_z = math.huge, math.huge, math.huge
    local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

    for xi = 1, 2 do
        for yi = 1, 2 do
            for zi = 1, 2 do
                local world_x, world_y, world_z = transform_local_point(
                    px, py, pz,
                    rx, ry, rz,
                    ux, uy, uz,
                    bx, by, bz,
                    xs[xi], ys[yi], zs[zi]
                )
                min_x = math.min(min_x, world_x)
                min_y = math.min(min_y, world_y)
                min_z = math.min(min_z, world_z)
                max_x = math.max(max_x, world_x)
                max_y = math.max(max_y, world_y)
                max_z = math.max(max_z, world_z)
            end
        end
    end

    return {
        min_x = min_x,
        min_y = min_y,
        min_z = min_z,
        max_x = max_x,
        max_y = max_y,
        max_z = max_z,
    }
end

function get_mesh_bounds_size(mesh_data)
    local mesh_bounds = (mesh_data and mesh_data.bounds) or UNIT_PART_BOUNDS
    return mesh_bounds,
        math.max((mesh_bounds.max_x or 1) - (mesh_bounds.min_x or 0), 1e-6),
        math.max((mesh_bounds.max_y or 1) - (mesh_bounds.min_y or 0), 1e-6),
        math.max((mesh_bounds.max_z or 1) - (mesh_bounds.min_z or 0), 1e-6)
end

function RBX._adjust_renderable_mesh_for_part_usage(mesh_data, part)
    return mesh_data
end
