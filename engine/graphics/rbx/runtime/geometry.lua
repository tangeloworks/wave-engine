function build_cube_vertices()
    local vertices = {}

    local function add_quad(v1, v2, v3, v4, nx, ny, nz)
        vertices[#vertices + 1] = { v1[1], v1[2], v1[3], nx, ny, nz }
        vertices[#vertices + 1] = { v2[1], v2[2], v2[3], nx, ny, nz }
        vertices[#vertices + 1] = { v3[1], v3[2], v3[3], nx, ny, nz }
        vertices[#vertices + 1] = { v1[1], v1[2], v1[3], nx, ny, nz }
        vertices[#vertices + 1] = { v3[1], v3[2], v3[3], nx, ny, nz }
        vertices[#vertices + 1] = { v4[1], v4[2], v4[3], nx, ny, nz }
    end

    -- +z
    add_quad(
        { -0.5, -0.5, 0.5 },
        { 0.5, -0.5, 0.5 },
        { 0.5, 0.5, 0.5 },
        { -0.5, 0.5, 0.5 },
        0, 0, 1
    )

    -- -z
    add_quad(
        { 0.5, -0.5, -0.5 },
        { -0.5, -0.5, -0.5 },
        { -0.5, 0.5, -0.5 },
        { 0.5, 0.5, -0.5 },
        0, 0, -1
    )

    -- +x
    add_quad(
        { 0.5, -0.5, 0.5 },
        { 0.5, -0.5, -0.5 },
        { 0.5, 0.5, -0.5 },
        { 0.5, 0.5, 0.5 },
        1, 0, 0
    )

    -- -x
    add_quad(
        { -0.5, -0.5, -0.5 },
        { -0.5, -0.5, 0.5 },
        { -0.5, 0.5, 0.5 },
        { -0.5, 0.5, -0.5 },
        -1, 0, 0
    )

    -- +y
    add_quad(
        { -0.5, 0.5, 0.5 },
        { 0.5, 0.5, 0.5 },
        { 0.5, 0.5, -0.5 },
        { -0.5, 0.5, -0.5 },
        0, 1, 0
    )

    -- -y
    add_quad(
        { -0.5, -0.5, -0.5 },
        { 0.5, -0.5, -0.5 },
        { 0.5, -0.5, 0.5 },
        { -0.5, -0.5, 0.5 },
        0, -1, 0
    )

    return vertices
end

function add_static_triangle(vertices, v1, v2, v3, nx, ny, nz)
    if nx == nil or ny == nil or nz == nil then
        local ax = v2[1] - v1[1]
        local ay = v2[2] - v1[2]
        local az = v2[3] - v1[3]
        local bx = v3[1] - v1[1]
        local by = v3[2] - v1[2]
        local bz = v3[3] - v1[3]
        nx, ny, nz = cross(ax, ay, az, bx, by, bz)
        nx, ny, nz = normalize_or_fallback(nx, ny, nz, 0, 1, 0)
    else
        nx, ny, nz = normalize_or_fallback(nx, ny, nz, 0, 1, 0)
    end

    vertices[#vertices + 1] = { v1[1], v1[2], v1[3], nx, ny, nz }
    vertices[#vertices + 1] = { v2[1], v2[2], v2[3], nx, ny, nz }
    vertices[#vertices + 1] = { v3[1], v3[2], v3[3], nx, ny, nz }
end

local function add_static_vertex(vertices, vertex, nx, ny, nz, fallback_nx, fallback_ny, fallback_nz)
    local normal_x, normal_y, normal_z = normalize_or_fallback(
        nx, ny, nz,
        fallback_nx or 0, fallback_ny or 1, fallback_nz or 0
    )
    vertices[#vertices + 1] = { vertex[1], vertex[2], vertex[3], normal_x, normal_y, normal_z }
end

local function add_static_triangle_with_normals_outward(vertices, v1, n1, v2, n2, v3, n3)
    local ax = v2[1] - v1[1]
    local ay = v2[2] - v1[2]
    local az = v2[3] - v1[3]
    local bx = v3[1] - v1[1]
    local by = v3[2] - v1[2]
    local bz = v3[3] - v1[3]
    local fallback_nx, fallback_ny, fallback_nz = cross(ax, ay, az, bx, by, bz)

    local cx = (v1[1] + v2[1] + v3[1]) / 3
    local cy = (v1[2] + v2[2] + v3[2]) / 3
    local cz = (v1[3] + v2[3] + v3[3]) / 3
    if dot(fallback_nx, fallback_ny, fallback_nz, cx, cy, cz) < 0 then
        v2, v3 = v3, v2
        n2, n3 = n3, n2
        fallback_nx, fallback_ny, fallback_nz = -fallback_nx, -fallback_ny, -fallback_nz
    end

    add_static_vertex(vertices, v1, n1[1], n1[2], n1[3], fallback_nx, fallback_ny, fallback_nz)
    add_static_vertex(vertices, v2, n2[1], n2[2], n2[3], fallback_nx, fallback_ny, fallback_nz)
    add_static_vertex(vertices, v3, n3[1], n3[2], n3[3], fallback_nx, fallback_ny, fallback_nz)
end

local function add_static_quad_with_normals_outward(vertices, v1, n1, v2, n2, v3, n3, v4, n4)
    add_static_triangle_with_normals_outward(vertices, v1, n1, v2, n2, v3, n3)
    add_static_triangle_with_normals_outward(vertices, v1, n1, v3, n3, v4, n4)
end

-- orient the triangle away from a point inside the solid
-- using an interior point keeps concave cut surfaces from relying on the world origin
function add_static_triangle_outward(vertices, v1, v2, v3, interior)
    local ax = v2[1] - v1[1]
    local ay = v2[2] - v1[2]
    local az = v2[3] - v1[3]
    local bx = v3[1] - v1[1]
    local by = v3[2] - v1[2]
    local bz = v3[3] - v1[3]
    local nx, ny, nz = cross(ax, ay, az, bx, by, bz)

    local ix, iy, iz = 0, 0, 0
    if interior then
        ix, iy, iz = interior[1], interior[2], interior[3]
    end

    local cx = (v1[1] + v2[1] + v3[1]) / 3 - ix
    local cy = (v1[2] + v2[2] + v3[2]) / 3 - iy
    local cz = (v1[3] + v2[3] + v3[3]) / 3 - iz
    if dot(nx, ny, nz, cx, cy, cz) < 0 then
        return add_static_triangle(vertices, v1, v3, v2, -nx, -ny, -nz)
    end
    return add_static_triangle(vertices, v1, v2, v3, nx, ny, nz)
end

function add_static_quad_outward(vertices, v1, v2, v3, v4, interior)
    add_static_triangle_outward(vertices, v1, v2, v3, interior)
    add_static_triangle_outward(vertices, v1, v3, v4, interior)
end

---Centroid of a vertex list. Inside any convex solid, which is all of these
local function centroid_of(...)
    local points = { ... }
    local n = #points
    local x, y, z = 0, 0, 0
    for i = 1, n do
        x = x + points[i][1]
        y = y + points[i][2]
        z = z + points[i][3]
    end
    return { x / n, y / n, z / n }
end

function add_static_box(vertices, min_x, min_y, min_z, max_x, max_y, max_z)
    -- the box centre, not the world origin. a truss is five beams and rungs that are
    -- deliberately OFF-origin, so eight of its sixty triangles were wound inward
    -- under the old origin-relative test
    local interior = {
        (min_x + max_x) * 0.5,
        (min_y + max_y) * 0.5,
        (min_z + max_z) * 0.5,
    }
    add_static_quad_outward(vertices,
        { min_x, min_y, max_z }, { max_x, min_y, max_z }, { max_x, max_y, max_z }, { min_x, max_y, max_z }, interior)
    add_static_quad_outward(vertices,
        { max_x, min_y, min_z }, { min_x, min_y, min_z }, { min_x, max_y, min_z }, { max_x, max_y, min_z }, interior)
    add_static_quad_outward(vertices,
        { max_x, min_y, max_z }, { max_x, min_y, min_z }, { max_x, max_y, min_z }, { max_x, max_y, max_z }, interior)
    add_static_quad_outward(vertices,
        { min_x, min_y, min_z }, { min_x, min_y, max_z }, { min_x, max_y, max_z }, { min_x, max_y, min_z }, interior)
    add_static_quad_outward(vertices,
        { min_x, max_y, max_z }, { max_x, max_y, max_z }, { max_x, max_y, min_z }, { min_x, max_y, min_z }, interior)
    add_static_quad_outward(vertices,
        { min_x, min_y, min_z }, { max_x, min_y, min_z }, { max_x, min_y, max_z }, { min_x, min_y, max_z }, interior)
end

geometry_centroid_of = centroid_of

function build_wedge_vertices()
    local vertices = {}

    -- slope faces -Z (LookVector) already, no rotation needed
    local p1 = { -0.5, -0.5, -0.5 }
    local p2 = { 0.5, -0.5, -0.5 }
    local p3 = { 0.5, -0.5, 0.5 }
    local p4 = { -0.5, -0.5, 0.5 }
    local p5 = { -0.5, 0.5, 0.5 }
    local p6 = { 0.5, 0.5, 0.5 }

    -- the wedge's own centroid, (0, -1/6, 1/6). the slope quad lies on the plane
    -- y = z which contains the world origin, so an origin-relative orientation test
    -- gives exactly 0.0 and leaves the face wound inward
    local interior = centroid_of(p1, p2, p3, p4, p5, p6)

    add_static_quad_outward(vertices, p1, p2, p3, p4, interior) -- bottom
    add_static_quad_outward(vertices, p4, p3, p6, p5, interior) -- back
    add_static_triangle_outward(vertices, p1, p4, p5, interior) -- left
    add_static_triangle_outward(vertices, p2, p6, p3, interior) -- right
    add_static_quad_outward(vertices, p1, p2, p6, p5, interior) -- slope

    return vertices
end

function build_corner_wedge_vertices()
    local vertices = {}

    local p1 = { -0.5, -0.5, -0.5 }
    local p2 = { 0.5, -0.5, -0.5 }
    local p3 = { 0.5, -0.5, 0.5 }
    local p4 = { -0.5, -0.5, 0.5 }
    local apex = { -0.5, 0.5, 0.5 }

    -- Centroid (-0.1, -0.3, 0.1). two of the corner wedge's slope planes also pass
    -- through the world origin, but unlike the wedge their supplied winding is
    -- already outward -- which is why the origin-relative test happened to work here
    -- and why "flip on <= 0" would have inverted this shape while fixing the wedge
    local interior = centroid_of(p1, p2, p3, p4, apex)

    add_static_quad_outward(vertices, p1, p2, p3, p4, interior) -- bottom
    add_static_triangle_outward(vertices, p1, p4, apex, interior)
    add_static_triangle_outward(vertices, p4, p3, apex, interior)
    add_static_triangle_outward(vertices, p2, p1, apex, interior)
    add_static_triangle_outward(vertices, p3, p2, apex, interior)

    -- roblox apex is (+X,-Z), local build has (-X,+Z) -- flip fixes it
    for i = 1, #vertices do
        local v = vertices[i]
        v[1] = -v[1]
        v[3] = -v[3]
        v[4] = -v[4]
        v[6] = -v[6]
    end

    return vertices
end

function build_cylinder_vertices(segments, axis)
    local vertices = {}
    segments = math.max(6, math.floor(segments or 18))
    axis = axis == "y" and "y" or "x"

    local radius = 0.5
    local center_pos
    local center_neg

    if axis == "x" then
        local x_min = -0.5
        local x_max = 0.5
        center_pos = { x_max, 0, 0 }
        center_neg = { x_min, 0, 0 }

        for i = 0, segments - 1 do
            local a0 = (i / segments) * math.pi * 2
            local a1 = ((i + 1) / segments) * math.pi * 2

            local y0 = math.cos(a0) * radius
            local z0 = math.sin(a0) * radius
            local y1 = math.cos(a1) * radius
            local z1 = math.sin(a1) * radius

            local s1 = { x_min, y0, z0 }
            local s2 = { x_max, y0, z0 }
            local s3 = { x_max, y1, z1 }
            local s4 = { x_min, y1, z1 }
            local n1 = { 0, y0 / radius, z0 / radius }
            local n2 = { 0, y0 / radius, z0 / radius }
            local n3 = { 0, y1 / radius, z1 / radius }
            local n4 = { 0, y1 / radius, z1 / radius }
            add_static_quad_with_normals_outward(vertices, s1, n1, s2, n2, s3, n3, s4, n4)

            local cp2 = { x_max, y0, z0 }
            local cp3 = { x_max, y1, z1 }
            add_static_triangle(vertices, center_pos, cp2, cp3, 1, 0, 0)

            local cn2 = { x_min, y1, z1 }
            local cn3 = { x_min, y0, z0 }
            add_static_triangle(vertices, center_neg, cn2, cn3, -1, 0, 0)
        end
    else
        local y_min = -0.5
        local y_max = 0.5
        center_pos = { 0, y_max, 0 }
        center_neg = { 0, y_min, 0 }

        for i = 0, segments - 1 do
            local a0 = (i / segments) * math.pi * 2
            local a1 = ((i + 1) / segments) * math.pi * 2

            local x0 = math.cos(a0) * radius
            local z0 = math.sin(a0) * radius
            local x1 = math.cos(a1) * radius
            local z1 = math.sin(a1) * radius

            local s1 = { x0, y_min, z0 }
            local s2 = { x0, y_max, z0 }
            local s3 = { x1, y_max, z1 }
            local s4 = { x1, y_min, z1 }
            local n1 = { x0 / radius, 0, z0 / radius }
            local n2 = { x0 / radius, 0, z0 / radius }
            local n3 = { x1 / radius, 0, z1 / radius }
            local n4 = { x1 / radius, 0, z1 / radius }
            add_static_quad_with_normals_outward(vertices, s1, n1, s2, n2, s3, n3, s4, n4)

            local cp2 = { x1, y_max, z1 }
            local cp3 = { x0, y_max, z0 }
            add_static_triangle(vertices, center_pos, cp2, cp3, 0, 1, 0)

            local cn2 = { x0, y_min, z0 }
            local cn3 = { x1, y_min, z1 }
            add_static_triangle(vertices, center_neg, cn2, cn3, 0, -1, 0)
        end
    end

    return vertices
end

function build_sphere_vertices(long_segments, lat_segments)
    local vertices = {}
    long_segments = math.max(8, math.floor(long_segments or 16))
    lat_segments = math.max(6, math.floor(lat_segments or 12))
    local radius = 0.5

    local function point(theta, phi)
        -- Canonical poles avoid one near-zero X/Z variant per longitude
        -- Besides making the topology deterministic, this lets the Menori
        -- vertex-map path share each pole exactly
        if theta <= -math.pi * 0.5 + 1e-12 then
            return { 0, -radius, 0 }
        end
        if theta >= math.pi * 0.5 - 1e-12 then
            return { 0, radius, 0 }
        end
        local cos_theta = math.cos(theta)
        return {
            cos_theta * math.cos(phi) * radius,
            math.sin(theta) * radius,
            cos_theta * math.sin(phi) * radius
        }
    end

    for y = 0, lat_segments - 1 do
        local t0 = ((y / lat_segments) - 0.5) * math.pi
        local t1 = (((y + 1) / lat_segments) - 0.5) * math.pi
        for x = 0, long_segments - 1 do
            local p0 = (x / long_segments) * math.pi * 2
            -- close the longitude seam with the exact same angle as its first
            -- column. sin(2*pi) is only approximately zero and otherwise
            -- defeats exact indexing along the seam
            local p1 = x == long_segments - 1
                and 0
                or ((x + 1) / long_segments) * math.pi * 2

            local v1 = point(t0, p0)
            local v2 = point(t0, p1)
            local v3 = point(t1, p1)
            local v4 = point(t1, p0)
            local n1 = { v1[1] / radius, v1[2] / radius, v1[3] / radius }
            local n2 = { v2[1] / radius, v2[2] / radius, v2[3] / radius }
            local n3 = { v3[1] / radius, v3[2] / radius, v3[3] / radius }
            local n4 = { v4[1] / radius, v4[2] / radius, v4[3] / radius }
            if y == 0 then
                -- v1/v2 are the same south-pole position. emit the one real
                -- fan triangle instead of also uploading a zero-area triangle
                add_static_triangle_with_normals_outward(
                    vertices, v1, n1, v3, n3, v4, n4)
            elseif y == lat_segments - 1 then
                -- v3/v4 coincide at the north pole, the second quad triangle
                -- would likewise be degenerate
                add_static_triangle_with_normals_outward(
                    vertices, v1, n1, v2, n2, v3, n3)
            else
                add_static_quad_with_normals_outward(
                    vertices,
                    v1, n1,
                    v2, n2,
                    v3, n3,
                    v4, n4
                )
            end
        end
    end

    return vertices
end

function build_truss_vertices()
    local vertices = {}

    local beam_width = 0.14
    local beam_depth = 0.14
    local half_depth = beam_depth * 0.5
    local rung_height = 0.10

    add_static_box(vertices, -0.5, -0.5, -half_depth, -0.5 + beam_width, 0.5, half_depth)
    add_static_box(vertices, 0.5 - beam_width, -0.5, -half_depth, 0.5, 0.5, half_depth)

    add_static_box(vertices, -0.5 + beam_width, -0.5, -half_depth, 0.5 - beam_width, -0.5 + rung_height, half_depth)
    add_static_box(vertices, -0.5 + beam_width, 0.5 - rung_height, -half_depth, 0.5 - beam_width, 0.5, half_depth)
    add_static_box(vertices, -0.5 + beam_width, -rung_height * 0.5, -half_depth, 0.5 - beam_width, rung_height * 0.5,
        half_depth)

    return vertices
end

function build_primitive_vertices()
    return {
        Block = build_cube_vertices(),
        Wedge = build_wedge_vertices(),
        CornerWedge = build_corner_wedge_vertices(),
        Cylinder = build_cylinder_vertices(18, "x"),
        CylinderY = build_cylinder_vertices(18, "y"),
        Ball = build_sphere_vertices(16, 12),
        Truss = build_truss_vertices(),
    }
end

-- front/back normals crossed vs roblox. shader hardcodes this layout -- dont touch
-- LEGACY table. Front/Back normals are INVERTED relative to Roblox's NormalId
-- convention (Roblox: Front = -Z, Back = +Z) and relative to DECAL_FACE_AXES and
-- SURFACE_GUI_CANVAS_FACE_AXES in this same file
--
-- the inversion is self-evident from the tangent frames: Right, Left, Top and Bottom
-- all satisfy u x v = +n, while Front and Back give u x v = -n. Flipping only the nz
-- sign on those two makes all six consistent and right-handed
--
-- Consequences of the inversion: surface-detail GEOMETRY (studs, inlets) is built on
-- the opposite face from the surface-overlay TEXTURE, and material projection
-- addresses +/-Z faces backwards. the CSG Z-mirror (mesh.lua flip_back_axis +
-- render.lua needs_csg_z_mirror) exists partly to COMPENSATE for this on unions,
-- which is why the two must be corrected together -- see FACE_AXES_ROBLOX below
FACE_AXES = {
    Right = { nx = 1, ny = 0, nz = 0, ux = 0, uy = 0, uz = -1, vx = 0, vy = 1, vz = 0, su = "z", sv = "y" },
    Left = { nx = -1, ny = 0, nz = 0, ux = 0, uy = 0, uz = 1, vx = 0, vy = 1, vz = 0, su = "z", sv = "y" },
    Top = { nx = 0, ny = 1, nz = 0, ux = 1, uy = 0, uz = 0, vx = 0, vy = 0, vz = 1, su = "x", sv = "z" },
    Bottom = { nx = 0, ny = -1, nz = 0, ux = 1, uy = 0, uz = 0, vx = 0, vy = 0, vz = -1, su = "x", sv = "z" },
    Front = { nx = 0, ny = 0, nz = 1, ux = -1, uy = 0, uz = 0, vx = 0, vy = 1, vz = 0, su = "x", sv = "y" },
    Back = { nx = 0, ny = 0, nz = -1, ux = 1, uy = 0, uz = 0, vx = 0, vy = 1, vz = 0, su = "x", sv = "y" },
}

-- Roblox-correct variant: identical except Front/Back nz are swapped, which also
-- makes every face's u x v = +n. Selected by the `accurate_face_axes` renderer
-- option, which ALSO removes the CSG Z-mirror -- the two are one atomic change
FACE_AXES_ROBLOX = {
    Right = { nx = 1, ny = 0, nz = 0, ux = 0, uy = 0, uz = -1, vx = 0, vy = 1, vz = 0, su = "z", sv = "y" },
    Left = { nx = -1, ny = 0, nz = 0, ux = 0, uy = 0, uz = 1, vx = 0, vy = 1, vz = 0, su = "z", sv = "y" },
    Top = { nx = 0, ny = 1, nz = 0, ux = 1, uy = 0, uz = 0, vx = 0, vy = 0, vz = 1, su = "x", sv = "z" },
    Bottom = { nx = 0, ny = -1, nz = 0, ux = 1, uy = 0, uz = 0, vx = 0, vy = 0, vz = -1, su = "x", sv = "z" },
    Front = { nx = 0, ny = 0, nz = -1, ux = -1, uy = 0, uz = 0, vx = 0, vy = 1, vz = 0, su = "x", sv = "y" },
    Back = { nx = 0, ny = 0, nz = 1, ux = 1, uy = 0, uz = 0, vx = 0, vy = 1, vz = 0, su = "x", sv = "y" },
}

---returns the active material-path face table
---kept as a function rather than a swapped global so the choice is explicit at every
---call site and cannot be captured stale by an upvalue
function get_material_face_axes()
    if RBX and RBX._accurate_face_axes then
        return FACE_AXES_ROBLOX
    end
    return FACE_AXES
end

-- normals follow roblox NormalId (front=-Z), top/bottom keep roblox's legacy decal quirk
DECAL_FACE_AXES = {
    Right = { nx = 1, ny = 0, nz = 0, ux = 0, uy = 0, uz = 1, vx = 0, vy = 1, vz = 0, su = "z", sv = "y" },
    Left = { nx = -1, ny = 0, nz = 0, ux = 0, uy = 0, uz = -1, vx = 0, vy = 1, vz = 0, su = "z", sv = "y" },
    Top = { nx = 0, ny = 1, nz = 0, ux = 1, uy = 0, uz = 0, vx = 0, vy = 0, vz = 1, su = "x", sv = "z" },
    Bottom = { nx = 0, ny = -1, nz = 0, ux = -1, uy = 0, uz = 0, vx = 0, vy = 0, vz = 1, su = "x", sv = "z" },
    Front = { nx = 0, ny = 0, nz = -1, ux = 1, uy = 0, uz = 0, vx = 0, vy = 1, vz = 0, su = "x", sv = "y" },
    Back = { nx = 0, ny = 0, nz = 1, ux = -1, uy = 0, uz = 0, vx = 0, vy = 1, vz = 0, su = "x", sv = "y" },
}

-- same as decal except top/bottom rotated 90deg (canvas dims are z,x not x,z)
SURFACE_GUI_CANVAS_FACE_AXES = {
    Right = DECAL_FACE_AXES.Right,
    Left = DECAL_FACE_AXES.Left,
    Top = { nx = 0, ny = 1, nz = 0, ux = 0, uy = 0, uz = 1, vx = -1, vy = 0, vz = 0, su = "z", sv = "x" },
    Bottom = { nx = 0, ny = -1, nz = 0, ux = 0, uy = 0, uz = 1, vx = 1, vy = 0, vz = 0, su = "z", sv = "x" },
    Front = DECAL_FACE_AXES.Front,
    Back = DECAL_FACE_AXES.Back,
}

function RBX._face_texture_axes_table(face_texture)
    if type(face_texture) == "table" and face_texture.source_kind == "SurfaceGui" then
        return SURFACE_GUI_CANVAS_FACE_AXES
    end
    return DECAL_FACE_AXES
end

MATERIAL_PROJECTION = {
    -- csg normal ids are 1-based, 0-based smears materials across csg unions
    CSG_NORMAL_ID_TO_FACE = {
        [1] = "Right",
        [2] = "Top",
        [3] = "Back",
        [4] = "Left",
        [5] = "Bottom",
        [6] = "Front",
    },
    -- read-only default for build_context callers that pass nil bounds
    _UNIT_BOUNDS = {
        min_x = -0.5,
        min_y = -0.5,
        min_z = -0.5,
        max_x = 0.5,
        max_y = 0.5,
        max_z = 0.5,
    },
}

function MATERIAL_PROJECTION.dominant_axis_face_name(nx, ny, nz)
    local abs_x = math.abs(nx or 0)
    local abs_y = math.abs(ny or 0)
    local abs_z = math.abs(nz or 0)

    if abs_x >= abs_y and abs_x >= abs_z then
        return (nx or 0) >= 0 and "Right" or "Left"
    end
    if abs_y >= abs_z then
        return (ny or 0) >= 0 and "Top" or "Bottom"
    end
    -- Roblox's object-space convention is Front=-Z, Back=+Z. keep the
    -- geometric fallback identical to the CSG NormalId table above, otherwise
    -- the same triangles project opposite material/decal faces depending on
    -- whether a mesh happened to carry explicit normal ids
    return (nz or 0) >= 0 and "Back" or "Front"
end

function MATERIAL_PROJECTION.swap_face_name(face_name, a, b)
    if face_name == a then
        return b
    end
    if face_name == b then
        return a
    end
    return face_name
end

function MATERIAL_PROJECTION.apply_face_mirror(face_name, mirror_x, mirror_y, mirror_z)
    local out = face_name
    if mirror_x then
        out = MATERIAL_PROJECTION.swap_face_name(out, "Right", "Left")
    end
    if mirror_y then
        out = MATERIAL_PROJECTION.swap_face_name(out, "Top", "Bottom")
    end
    if mirror_z then
        out = MATERIAL_PROJECTION.swap_face_name(out, "Front", "Back")
    end
    return out
end

function MATERIAL_PROJECTION.scale_bounds_axis(min_value, max_value, scale)
    local a = (min_value or 0) * (scale or 1)
    local b = (max_value or 0) * (scale or 1)
    if a <= b then
        return a, b
    end
    return b, a
end

function MATERIAL_PROJECTION.build_context_into(context, scaled_bounds, bounds,
                                                scale_x, scale_y, scale_z,
                                                extra_mirror_x, extra_mirror_y, extra_mirror_z)
    -- shared constant: build_context only reads source_bounds, and this default was
    -- reallocated once per part on the material path
    local source_bounds = bounds or MATERIAL_PROJECTION._UNIT_BOUNDS

    context = context or {}
    scaled_bounds = scaled_bounds or context.bounds or {}

    scaled_bounds.min_x, scaled_bounds.max_x = MATERIAL_PROJECTION.scale_bounds_axis(
        source_bounds.min_x,
        source_bounds.max_x,
        scale_x
    )
    scaled_bounds.min_y, scaled_bounds.max_y = MATERIAL_PROJECTION.scale_bounds_axis(
        source_bounds.min_y,
        source_bounds.max_y,
        scale_y
    )
    scaled_bounds.min_z, scaled_bounds.max_z = MATERIAL_PROJECTION.scale_bounds_axis(
        source_bounds.min_z,
        source_bounds.max_z,
        scale_z
    )

    local mirror_x = (scale_x or 1) < 0
    local mirror_y = (scale_y or 1) < 0
    local mirror_z = (scale_z or 1) < 0

    if extra_mirror_x then
        scaled_bounds.min_x, scaled_bounds.max_x = -scaled_bounds.max_x, -scaled_bounds.min_x
        mirror_x = not mirror_x
    end
    if extra_mirror_y then
        scaled_bounds.min_y, scaled_bounds.max_y = -scaled_bounds.max_y, -scaled_bounds.min_y
        mirror_y = not mirror_y
    end
    if extra_mirror_z then
        scaled_bounds.min_z, scaled_bounds.max_z = -scaled_bounds.max_z, -scaled_bounds.min_z
        mirror_z = not mirror_z
    end

    context.bounds = scaled_bounds
    context.mirror_x = mirror_x
    context.mirror_y = mirror_y
    context.mirror_z = mirror_z
    context.extra_mirror_x = extra_mirror_x and true or false
    context.extra_mirror_y = extra_mirror_y and true or false
    context.extra_mirror_z = extra_mirror_z and true or false
    return context
end

function MATERIAL_PROJECTION.build_context(bounds,
                                           scale_x, scale_y, scale_z,
                                           extra_mirror_x, extra_mirror_y, extra_mirror_z)
    return MATERIAL_PROJECTION.build_context_into(
        {}, {}, bounds,
        scale_x, scale_y, scale_z,
        extra_mirror_x, extra_mirror_y, extra_mirror_z)
end

function MATERIAL_PROJECTION.get_range(bounds, ax, ay, az)
    if ax ~= 0 then
        if ax > 0 then
            return bounds.min_x, bounds.max_x
        end
        return -bounds.max_x, -bounds.min_x
    end
    if ay ~= 0 then
        if ay > 0 then
            return bounds.min_y, bounds.max_y
        end
        return -bounds.max_y, -bounds.min_y
    end
    if az > 0 then
        return bounds.min_z, bounds.max_z
    end
    return -bounds.max_z, -bounds.min_z
end

function RBX._get_face_texture_wrap_mode(face_texture)
    if type(face_texture) == "table" and face_texture.class_name == "Texture" then
        return "repeat"
    end
    return "clamp"
end

function RBX._get_face_texture_runtime_sampler_wrap_mode(face_texture)
    if type(face_texture) ~= "table" then return nil end
    local object = face_texture.texture_object
    if object == nil and type(face_texture.texture) ~= "string" then
        object = face_texture.texture
    end
    if object ~= nil and type(object.setWrap) == "function" then
        return RBX._get_face_texture_wrap_mode(face_texture)
    end
    return nil
end

local function finite_face_uv_number(value, fallback)
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then
        return fallback
    end
    return value
end

-- Decal's modern UV properties operate on logical projected face coordinates
-- Most legacy face batches retain a shader-space orientation flip. when those
-- flips are active, conjugating the authored transform by the same involution
-- makes the shader observe T(F(raw)) rather than F(T(raw)), in particular a
-- positive UVOffset stays positive in sampled texture space. the transformed-
-- region rotation pivot below is the best current compatibility model, but is
-- deliberately isolated pending a native asymmetric-texture pixel oracle
function RBX._transform_face_texture_uv(face_texture, u, v, flip_u, flip_v)
    if type(face_texture) ~= "table" then
        return u, v
    end
    local class_name = face_texture.class_name
    if class_name == 'SurfaceGui' then
        local gui=face_texture.surface_gui_ref
        local raster=gui and gui._runtime_state and gui._runtime_state.raster_bounds
        if raster then
            if flip_u then u=1-u end
            if flip_v then v=1-v end
            u=(u*raster.logical_w-raster.x)/raster.w
            v=(v*raster.logical_h-raster.y)/raster.h
            if flip_u then u=1-u end
            if flip_v then v=1-v end
        end
        return u,v
    end
    if class_name ~= "Decal" and class_name ~= "Texture" then
        return u, v
    end

    local scale_u = finite_face_uv_number(face_texture.uv_scale_u, 1)
    local scale_v = finite_face_uv_number(face_texture.uv_scale_v, 1)
    local offset_u = finite_face_uv_number(face_texture.uv_offset_u, 0)
    local offset_v = finite_face_uv_number(face_texture.uv_offset_v, 0)
    local rotation = finite_face_uv_number(face_texture.rotation, 0)

    if flip_u then u = 1 - u end
    if flip_v then v = 1 - v end

    u = u * scale_u + offset_u
    v = v * scale_v + offset_v

    rotation = rotation % 360
    if rotation ~= 0 then
        local radians = math.rad(rotation)
        local cosine = math.cos(radians)
        local sine = math.sin(radians)
        local pivot_u = 0.5 * scale_u + offset_u
        local pivot_v = 0.5 * scale_v + offset_v
        local delta_u = u - pivot_u
        local delta_v = v - pivot_v
        u = pivot_u + cosine * delta_u - sine * delta_v
        v = pivot_v + sine * delta_u + cosine * delta_v
    end

    if flip_u then u = 1 - u end
    if flip_v then v = 1 - v end

    return u, v
end

function RBX._project_face_texture_uv(face_texture, face_name, bounds, lx, ly, lz, flip_u, flip_v)
    local axes_table = RBX._face_texture_axes_table(face_texture)
    local axis = axes_table[face_name] or axes_table.Front
    local projection = nil
    local active_bounds = bounds
    if type(bounds) == "table" and
        (bounds.bounds ~= nil or bounds.extra_mirror_x ~= nil or bounds.extra_mirror_y ~= nil or bounds.extra_mirror_z ~= nil) then
        projection = bounds
        active_bounds = bounds.bounds
    end
    active_bounds = active_bounds or {
        min_x = -0.5,
        min_y = -0.5,
        min_z = -0.5,
        max_x = 0.5,
        max_y = 0.5,
        max_z = 0.5,
    }
    if projection then
        if projection.extra_mirror_x then
            lx = -lx
        end
        if projection.extra_mirror_y then
            ly = -ly
        end
        if projection.extra_mirror_z then
            lz = -lz
        end
    end
    local min_u, max_u = MATERIAL_PROJECTION.get_range(active_bounds, axis.ux, axis.uy, axis.uz)
    local min_v, max_v = MATERIAL_PROJECTION.get_range(active_bounds, axis.vx, axis.vy, axis.vz)
    local coord_u = axis.ux * lx + axis.uy * ly + axis.uz * lz
    local coord_v = axis.vx * lx + axis.vy * ly + axis.vz * lz

    if type(face_texture) == "table" and face_texture.class_name == "Texture" then
        -- Texture inherits Decal's face orientation, only its scale/repeat
        -- contract differs. the old per-face mirror tables reversed one axis
        -- on four faces, so the same image changed handedness when switching
        -- between Decal and Texture and OffsetStuds changed direction with it
        -- Roblox defaults each tile dimension independently to two studs
        local studs_per_tile_u = math.max(0.001,
            finite_face_uv_number(face_texture.studs_per_tile_u, 2))
        local studs_per_tile_v = math.max(0.001,
            finite_face_uv_number(face_texture.studs_per_tile_v, 2))
        local offset_studs_u = finite_face_uv_number(face_texture.offset_studs_u, 0)
        local offset_studs_v = finite_face_uv_number(face_texture.offset_studs_v, 0)
        local along_u = coord_u - min_u
        local along_v = coord_v - min_v
        return RBX._transform_face_texture_uv(
            face_texture,
            (along_u + offset_studs_u) / studs_per_tile_u,
            (along_v + offset_studs_v) / studs_per_tile_v,
            flip_u,
            flip_v
        )
    end

    local span_u = math.max(max_u - min_u, 1e-6)
    local span_v = math.max(max_v - min_v, 1e-6)
    return RBX._transform_face_texture_uv(
        face_texture,
        (coord_u - min_u) / span_u,
        (coord_v - min_v) / span_v,
        flip_u,
        flip_v
    )
end

function MATERIAL_PROJECTION.select_face_name(normal_id, nx, ny, nz, projection)
    local face_name = nil
    if normal_id ~= nil then
        face_name = MATERIAL_PROJECTION.CSG_NORMAL_ID_TO_FACE[math.floor(tonumber(normal_id) or 0)]
    end
    if face_name then
        if projection then
            face_name = MATERIAL_PROJECTION.apply_face_mirror(
                face_name,
                projection.mirror_x,
                projection.mirror_y,
                projection.mirror_z
            )
        end
        return face_name
    end

    face_name = MATERIAL_PROJECTION.dominant_axis_face_name(nx, ny, nz)
    if projection then
        face_name = MATERIAL_PROJECTION.apply_face_mirror(
            face_name,
            projection.mirror_x,
            projection.mirror_y,
            projection.mirror_z
        )
    end
    return face_name
end

function RBX._build_material_projection_context(bounds,
                                                scale_x, scale_y, scale_z,
                                                extra_mirror_x, extra_mirror_y, extra_mirror_z)
    return MATERIAL_PROJECTION.build_context(bounds, scale_x, scale_y, scale_z, extra_mirror_x, extra_mirror_y,
        extra_mirror_z)
end

function RBX._select_material_face_name(normal_id, nx, ny, nz, projection)
    return MATERIAL_PROJECTION.select_face_name(normal_id, nx, ny, nz, projection)
end

function get_face_plane_coordinate(bounds, axis)
    if axis.nx > 0 then
        return bounds.max_x or 0.5
    end
    if axis.nx < 0 then
        return -(bounds.min_x or -0.5)
    end
    if axis.ny > 0 then
        return bounds.max_y or 0.5
    end
    if axis.ny < 0 then
        return -(bounds.min_y or -0.5)
    end
    if axis.nz > 0 then
        return bounds.max_z or 0.5
    end
    return -(bounds.min_z or -0.5)
end

function get_face_plane_span(bounds, axis)
    if axis.nx ~= 0 then
        return math.max(1e-6, math.abs((bounds.max_x or 0.5) - (bounds.min_x or -0.5)))
    end
    if axis.ny ~= 0 then
        return math.max(1e-6, math.abs((bounds.max_y or 0.5) - (bounds.min_y or -0.5)))
    end
    return math.max(1e-6, math.abs((bounds.max_z or 0.5) - (bounds.min_z or -0.5)))
end

function RBX._prepare_mesh_decal_face_matcher(face_name, bounds, opts)
    local axis = DECAL_FACE_AXES[face_name]
    if not axis or type(bounds) ~= "table" then
        return nil
    end

    return {
        face_name = face_name,
        nx = axis.nx,
        ny = axis.ny,
        nz = axis.nz,
        plane_coordinate = get_face_plane_coordinate(bounds, axis),
        plane_tolerance = math.max(
            0.004, get_face_plane_span(bounds, axis) * 0.08),
        primitive_shape = type(opts) == "table"
            and opts.primitive_shape or nil,
        source_face_name = type(opts) == "table"
            and opts.source_face_name or nil,
        mesh_projection = type(opts) == "table" and opts.mesh_projection == true,
    }
end

-- the optional unit vectors let mesh/primitive callers normalize each triangle
-- once before testing several authored face layers. Nil preserves the public
-- wrapper's exact degenerate-vector fallback semantics
function RBX._mesh_decal_triangle_matches_prepared(
    matcher, triangle,
    tri_unit_x, tri_unit_y, tri_unit_z,
    avg_unit_x, avg_unit_y, avg_unit_z)
    if type(matcher) ~= "table" or type(triangle) ~= "table" then
        return false
    end

    local tri_nx, tri_ny, tri_nz =
        tri_unit_x, tri_unit_y, tri_unit_z
    if tri_nx == nil or tri_ny == nil or tri_nz == nil
        or (tri_nx == 0 and tri_ny == 0 and tri_nz == 0) then
        tri_nx, tri_ny, tri_nz = normalize_or_fallback(
            triangle.tri_nx or 0,
            triangle.tri_ny or 0,
            triangle.tri_nz or 0,
            matcher.nx, matcher.ny, matcher.nz)
    end
    local avg_nx, avg_ny, avg_nz =
        avg_unit_x, avg_unit_y, avg_unit_z
    if avg_nx == nil or avg_ny == nil or avg_nz == nil
        or (avg_nx == 0 and avg_ny == 0 and avg_nz == 0) then
        avg_nx, avg_ny, avg_nz = normalize_or_fallback(
            triangle.avg_nx or tri_nx,
            triangle.avg_ny or tri_ny,
            triangle.avg_nz or tri_nz,
            tri_nx, tri_ny, tri_nz)
    end

    -- wedge slopes map by table not plane (wedge top+front are both the slope), planar tris fall to the test below
    local primitive_shape = matcher.primitive_shape
    if primitive_shape == "Wedge" or primitive_shape == "CornerWedge" then
        local anx, any, anz = math.abs(tri_nx), math.abs(tri_ny), math.abs(tri_nz)
        local is_slope = math.max(anx, any, anz) < 0.99
        if is_slope then
            -- tri normals are part-local, match the source face so it holds under map mirror
            local match_face = matcher.source_face_name
                or matcher.face_name
            if primitive_shape == "Wedge" then
                return match_face == "Top" or match_face == "Front"
            end
            if match_face == "Top" then return true end
            if match_face == "Back" then return tri_nz > 0.01 end
            if match_face == "Left" then return tri_nx < -0.01 end
            return false
        end
    end

    if matcher.mesh_projection then
        -- an orthographic mesh decal projects onto outward-facing geometry,
        -- not an eight-percent slab at the bounding-box plane. Smooth vertex
        -- normals shade the result, they must not reject the curved forehead
        if (triangle.tri_nx or 0)==0 and (triangle.tri_ny or 0)==0 and (triangle.tri_nz or 0)==0 then return false end
        return dot(tri_nx,tri_ny,tri_nz,matcher.nx,matcher.ny,matcher.nz)>1e-8
    end
    local normal_alignment = dot(
        avg_nx, avg_ny, avg_nz,
        matcher.nx, matcher.ny, matcher.nz)
    if normal_alignment < 0.35 then
        return false
    end

    local winding_alignment = dot(
        tri_nx, tri_ny, tri_nz,
        matcher.nx, matcher.ny, matcher.nz)
    if winding_alignment < 0.2 then
        return false
    end

    local face_coordinate = dot(
        triangle.cx or 0,
        triangle.cy or 0,
        triangle.cz or 0,
        matcher.nx,
        matcher.ny,
        matcher.nz
    )
    if math.abs(face_coordinate - matcher.plane_coordinate)
        > matcher.plane_tolerance then
        return false
    end

    return true
end

function RBX._clip_projected_decal_triangle(vertices,face_texture)
    if face_texture.class_name=='Texture' then return vertices end
    local inside=true
    for i=1,3 do local v=vertices[i];if v.u<0 or v.u>1 or v.v<0 or v.v>1 then inside=false;break end end
    if inside then return vertices end
    local polygon={vertices[1],vertices[2],vertices[3]}
    for _,plane in ipairs{{'u',0,1},{'u',1,-1},{'v',0,1},{'v',1,-1}} do
        local result={};local previous=polygon[#polygon]
        if not previous then return result end
        local pd=(previous[plane[1]]-plane[2])*plane[3]
        for _,current in ipairs(polygon)do
            local cd=(current[plane[1]]-plane[2])*plane[3]
            if (cd>=0)~=(pd>=0)then
                local fraction=pd/(pd-cd);local vertex={}
                for _,key in ipairs{'x','y','z','lx','ly','lz','nx','ny','nz','u','v'}do
                    vertex[key]=previous[key]+(current[key]-previous[key])*fraction
                end
                result[#result+1]=vertex
            end
            if cd>=0 then result[#result+1]=current end
            previous,pd=current,cd
        end
        polygon=result
    end
    return polygon
end

function RBX._mesh_decal_triangle_matches_face(
    face_name, bounds, triangle, opts)
    local matcher = RBX._prepare_mesh_decal_face_matcher(
        face_name, bounds, opts)
    return RBX._mesh_decal_triangle_matches_prepared(
        matcher, triangle)
end

function MATERIAL_PROJECTION.project_uv(face_name, projection, lx, ly, lz, studs_per_tile, tiling)
    local face_axes = get_material_face_axes()
    local axis = face_axes[face_name] or face_axes.Front
    local bounds = projection and projection.bounds or {
        min_x = -0.5,
        min_y = -0.5,
        min_z = -0.5,
        max_x = 0.5,
        max_y = 0.5,
        max_z = 0.5,
    }
    if projection then
        if projection.extra_mirror_x then
            lx = -lx
        end
        if projection.extra_mirror_y then
            ly = -ly
        end
        if projection.extra_mirror_z then
            lz = -lz
        end
    end
    local min_u = MATERIAL_PROJECTION.get_range(bounds, axis.ux, axis.uy, axis.uz)
    local min_v = MATERIAL_PROJECTION.get_range(bounds, axis.vx, axis.vy, axis.vz)
    local u = axis.ux * lx + axis.uy * ly + axis.uz * lz
    local v = axis.vx * lx + axis.vy * ly + axis.vz * lz
    local studs = math.max(0.001, studs_per_tile or MATERIAL_STUDS_PER_TILE)
    local repeat_scale = math.max(0.001, tiling or 1)
    return ((u - min_u) / studs) * repeat_scale,
        ((v - min_v) / studs) * repeat_scale
end
