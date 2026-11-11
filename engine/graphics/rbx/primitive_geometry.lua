-- pure, worker-safe Roblox primitive geometry
--
-- the renderer currently owns an equivalent builder in runtime/geometry.lua
-- this module deliberately has no LOVE/renderer dependency so model-container
-- mesh composition can run in a decode worker.  a later mechanical tranche can
-- make runtime/geometry.lua alias these functions and remove the temporary
-- duplication after corpus parity is pinned

local Geometry = {}

local function cross(ax, ay, az, bx, by, bz)
    return ay * bz - az * by,
        az * bx - ax * bz,
        ax * by - ay * bx
end

local function dot(ax, ay, az, bx, by, bz)
    return ax * bx + ay * by + az * bz
end

local function normalize(x, y, z, fx, fy, fz)
    local length = math.sqrt(x * x + y * y + z * z)
    if length <= 1e-12 or length ~= length then
        return fx or 0, fy or 1, fz or 0
    end
    return x / length, y / length, z / length
end

local function add_vertex(vertices, vertex, nx, ny, nz, fx, fy, fz)
    nx, ny, nz = normalize(nx, ny, nz, fx, fy, fz)
    vertices[#vertices + 1] = {
        vertex[1], vertex[2], vertex[3], nx, ny, nz,
    }
end

local function add_triangle(vertices, v1, v2, v3, nx, ny, nz)
    if nx == nil then
        nx, ny, nz = cross(
            v2[1] - v1[1], v2[2] - v1[2], v2[3] - v1[3],
            v3[1] - v1[1], v3[2] - v1[2], v3[3] - v1[3])
    end
    nx, ny, nz = normalize(nx, ny, nz, 0, 1, 0)
    vertices[#vertices + 1] = { v1[1], v1[2], v1[3], nx, ny, nz }
    vertices[#vertices + 1] = { v2[1], v2[2], v2[3], nx, ny, nz }
    vertices[#vertices + 1] = { v3[1], v3[2], v3[3], nx, ny, nz }
end

local function add_triangle_with_normals_outward(vertices, v1, n1, v2, n2, v3, n3)
    local nx, ny, nz = cross(
        v2[1] - v1[1], v2[2] - v1[2], v2[3] - v1[3],
        v3[1] - v1[1], v3[2] - v1[2], v3[3] - v1[3])
    local cx = (v1[1] + v2[1] + v3[1]) / 3
    local cy = (v1[2] + v2[2] + v3[2]) / 3
    local cz = (v1[3] + v2[3] + v3[3]) / 3
    if dot(nx, ny, nz, cx, cy, cz) < 0 then
        v2, v3, n2, n3 = v3, v2, n3, n2
        nx, ny, nz = -nx, -ny, -nz
    end
    add_vertex(vertices, v1, n1[1], n1[2], n1[3], nx, ny, nz)
    add_vertex(vertices, v2, n2[1], n2[2], n2[3], nx, ny, nz)
    add_vertex(vertices, v3, n3[1], n3[2], n3[3], nx, ny, nz)
end

local function add_quad_with_normals_outward(vertices, v1, n1, v2, n2, v3, n3, v4, n4)
    add_triangle_with_normals_outward(vertices, v1, n1, v2, n2, v3, n3)
    add_triangle_with_normals_outward(vertices, v1, n1, v3, n3, v4, n4)
end

local function add_triangle_outward(vertices, v1, v2, v3, interior)
    local nx, ny, nz = cross(
        v2[1] - v1[1], v2[2] - v1[2], v2[3] - v1[3],
        v3[1] - v1[1], v3[2] - v1[2], v3[3] - v1[3])
    local ix, iy, iz = 0, 0, 0
    if interior then ix, iy, iz = interior[1], interior[2], interior[3] end
    local cx = (v1[1] + v2[1] + v3[1]) / 3 - ix
    local cy = (v1[2] + v2[2] + v3[2]) / 3 - iy
    local cz = (v1[3] + v2[3] + v3[3]) / 3 - iz
    if dot(nx, ny, nz, cx, cy, cz) < 0 then
        return add_triangle(vertices, v1, v3, v2, -nx, -ny, -nz)
    end
    return add_triangle(vertices, v1, v2, v3, nx, ny, nz)
end

local function add_quad_outward(vertices, v1, v2, v3, v4, interior)
    add_triangle_outward(vertices, v1, v2, v3, interior)
    add_triangle_outward(vertices, v1, v3, v4, interior)
end

local function centroid(...)
    local points = { ... }
    local x, y, z = 0, 0, 0
    for index = 1, #points do
        x = x + points[index][1]
        y = y + points[index][2]
        z = z + points[index][3]
    end
    return { x / #points, y / #points, z / #points }
end

local function add_box(vertices, min_x, min_y, min_z, max_x, max_y, max_z)
    local interior = {
        (min_x + max_x) * 0.5,
        (min_y + max_y) * 0.5,
        (min_z + max_z) * 0.5,
    }
    add_quad_outward(vertices,
        { min_x, min_y, max_z }, { max_x, min_y, max_z },
        { max_x, max_y, max_z }, { min_x, max_y, max_z }, interior)
    add_quad_outward(vertices,
        { max_x, min_y, min_z }, { min_x, min_y, min_z },
        { min_x, max_y, min_z }, { max_x, max_y, min_z }, interior)
    add_quad_outward(vertices,
        { max_x, min_y, max_z }, { max_x, min_y, min_z },
        { max_x, max_y, min_z }, { max_x, max_y, max_z }, interior)
    add_quad_outward(vertices,
        { min_x, min_y, min_z }, { min_x, min_y, max_z },
        { min_x, max_y, max_z }, { min_x, max_y, min_z }, interior)
    add_quad_outward(vertices,
        { min_x, max_y, max_z }, { max_x, max_y, max_z },
        { max_x, max_y, min_z }, { min_x, max_y, min_z }, interior)
    add_quad_outward(vertices,
        { min_x, min_y, min_z }, { max_x, min_y, min_z },
        { max_x, min_y, max_z }, { min_x, min_y, max_z }, interior)
end

function Geometry.build_cube_vertices()
    local vertices = {}
    local function quad(v1, v2, v3, v4, nx, ny, nz)
        vertices[#vertices + 1] = { v1[1], v1[2], v1[3], nx, ny, nz }
        vertices[#vertices + 1] = { v2[1], v2[2], v2[3], nx, ny, nz }
        vertices[#vertices + 1] = { v3[1], v3[2], v3[3], nx, ny, nz }
        vertices[#vertices + 1] = { v1[1], v1[2], v1[3], nx, ny, nz }
        vertices[#vertices + 1] = { v3[1], v3[2], v3[3], nx, ny, nz }
        vertices[#vertices + 1] = { v4[1], v4[2], v4[3], nx, ny, nz }
    end
    quad({ -0.5, -0.5, 0.5 }, { 0.5, -0.5, 0.5 },
        { 0.5, 0.5, 0.5 }, { -0.5, 0.5, 0.5 }, 0, 0, 1)
    quad({ 0.5, -0.5, -0.5 }, { -0.5, -0.5, -0.5 },
        { -0.5, 0.5, -0.5 }, { 0.5, 0.5, -0.5 }, 0, 0, -1)
    quad({ 0.5, -0.5, 0.5 }, { 0.5, -0.5, -0.5 },
        { 0.5, 0.5, -0.5 }, { 0.5, 0.5, 0.5 }, 1, 0, 0)
    quad({ -0.5, -0.5, -0.5 }, { -0.5, -0.5, 0.5 },
        { -0.5, 0.5, 0.5 }, { -0.5, 0.5, -0.5 }, -1, 0, 0)
    quad({ -0.5, 0.5, 0.5 }, { 0.5, 0.5, 0.5 },
        { 0.5, 0.5, -0.5 }, { -0.5, 0.5, -0.5 }, 0, 1, 0)
    quad({ -0.5, -0.5, -0.5 }, { 0.5, -0.5, -0.5 },
        { 0.5, -0.5, 0.5 }, { -0.5, -0.5, 0.5 }, 0, -1, 0)
    return vertices
end

function Geometry.build_wedge_vertices()
    local vertices = {}
    local p1, p2 = { -0.5, -0.5, -0.5 }, { 0.5, -0.5, -0.5 }
    local p3, p4 = { 0.5, -0.5, 0.5 }, { -0.5, -0.5, 0.5 }
    local p5, p6 = { -0.5, 0.5, 0.5 }, { 0.5, 0.5, 0.5 }
    local interior = centroid(p1, p2, p3, p4, p5, p6)
    add_quad_outward(vertices, p1, p2, p3, p4, interior)
    add_quad_outward(vertices, p4, p3, p6, p5, interior)
    add_triangle_outward(vertices, p1, p4, p5, interior)
    add_triangle_outward(vertices, p2, p6, p3, interior)
    add_quad_outward(vertices, p1, p2, p6, p5, interior)
    return vertices
end

function Geometry.build_corner_wedge_vertices()
    local vertices = {}
    local p1, p2 = { -0.5, -0.5, -0.5 }, { 0.5, -0.5, -0.5 }
    local p3, p4 = { 0.5, -0.5, 0.5 }, { -0.5, -0.5, 0.5 }
    local apex = { -0.5, 0.5, 0.5 }
    local interior = centroid(p1, p2, p3, p4, apex)
    add_quad_outward(vertices, p1, p2, p3, p4, interior)
    add_triangle_outward(vertices, p1, p4, apex, interior)
    add_triangle_outward(vertices, p4, p3, apex, interior)
    add_triangle_outward(vertices, p2, p1, apex, interior)
    add_triangle_outward(vertices, p3, p2, apex, interior)
    for index = 1, #vertices do
        local vertex = vertices[index]
        vertex[1], vertex[3] = -vertex[1], -vertex[3]
        vertex[4], vertex[6] = -vertex[4], -vertex[6]
    end
    return vertices
end


function Geometry.build_cylinder_vertices(segments, axis)
    local vertices = {}
    segments = math.max(6, math.floor(segments or 18))
    axis = axis == "y" and "y" or "x"
    local radius = 0.5
    if axis == "x" then
        local x_min, x_max = -0.5, 0.5
        local center_pos, center_neg = { x_max, 0, 0 }, { x_min, 0, 0 }
        for index = 0, segments - 1 do
            local a0 = (index / segments) * math.pi * 2
            local a1 = ((index + 1) / segments) * math.pi * 2
            local y0, z0 = math.cos(a0) * radius, math.sin(a0) * radius
            local y1, z1 = math.cos(a1) * radius, math.sin(a1) * radius
            add_quad_with_normals_outward(vertices,
                { x_min, y0, z0 }, { 0, y0 / radius, z0 / radius },
                { x_max, y0, z0 }, { 0, y0 / radius, z0 / radius },
                { x_max, y1, z1 }, { 0, y1 / radius, z1 / radius },
                { x_min, y1, z1 }, { 0, y1 / radius, z1 / radius })
            add_triangle(vertices, center_pos,
                { x_max, y0, z0 }, { x_max, y1, z1 }, 1, 0, 0)
            add_triangle(vertices, center_neg,
                { x_min, y1, z1 }, { x_min, y0, z0 }, -1, 0, 0)
        end
    else
        local y_min, y_max = -0.5, 0.5
        local center_pos, center_neg = { 0, y_max, 0 }, { 0, y_min, 0 }
        for index = 0, segments - 1 do
            local a0 = (index / segments) * math.pi * 2
            local a1 = ((index + 1) / segments) * math.pi * 2
            local x0, z0 = math.cos(a0) * radius, math.sin(a0) * radius
            local x1, z1 = math.cos(a1) * radius, math.sin(a1) * radius
            add_quad_with_normals_outward(vertices,
                { x0, y_min, z0 }, { x0 / radius, 0, z0 / radius },
                { x0, y_max, z0 }, { x0 / radius, 0, z0 / radius },
                { x1, y_max, z1 }, { x1 / radius, 0, z1 / radius },
                { x1, y_min, z1 }, { x1 / radius, 0, z1 / radius })
            add_triangle(vertices, center_pos,
                { x1, y_max, z1 }, { x0, y_max, z0 }, 0, 1, 0)
            add_triangle(vertices, center_neg,
                { x0, y_min, z0 }, { x1, y_min, z1 }, 0, -1, 0)
        end
    end
    return vertices
end

function Geometry.build_sphere_vertices(long_segments, lat_segments)
    local vertices = {}
    long_segments = math.max(8, math.floor(long_segments or 16))
    lat_segments = math.max(6, math.floor(lat_segments or 12))
    local radius = 0.5
    local function point(theta, phi)
        if theta <= -math.pi * 0.5 + 1e-12 then return { 0, -radius, 0 } end
        if theta >= math.pi * 0.5 - 1e-12 then return { 0, radius, 0 } end
        local cosine = math.cos(theta)
        return {
            cosine * math.cos(phi) * radius,
            math.sin(theta) * radius,
            cosine * math.sin(phi) * radius,
        }
    end
    for latitude = 0, lat_segments - 1 do
        local t0 = ((latitude / lat_segments) - 0.5) * math.pi
        local t1 = (((latitude + 1) / lat_segments) - 0.5) * math.pi
        for longitude = 0, long_segments - 1 do
            local p0 = (longitude / long_segments) * math.pi * 2
            local p1 = longitude == long_segments - 1
                and 0 or ((longitude + 1) / long_segments) * math.pi * 2
            local v1, v2, v3, v4 = point(t0, p0), point(t0, p1),
                point(t1, p1), point(t1, p0)
            local n1 = { v1[1] / radius, v1[2] / radius, v1[3] / radius }
            local n2 = { v2[1] / radius, v2[2] / radius, v2[3] / radius }
            local n3 = { v3[1] / radius, v3[2] / radius, v3[3] / radius }
            local n4 = { v4[1] / radius, v4[2] / radius, v4[3] / radius }
            if latitude == 0 then
                add_triangle_with_normals_outward(vertices, v1, n1, v3, n3, v4, n4)
            elseif latitude == lat_segments - 1 then
                add_triangle_with_normals_outward(vertices, v1, n1, v2, n2, v3, n3)
            else
                add_quad_with_normals_outward(vertices,
                    v1, n1, v2, n2, v3, n3, v4, n4)
            end
        end
    end
    return vertices
end

function Geometry.build_truss_vertices()
    local vertices = {}
    local beam_width, beam_depth, rung_height = 0.14, 0.14, 0.10
    local half_depth = beam_depth * 0.5
    add_box(vertices, -0.5, -0.5, -half_depth,
        -0.5 + beam_width, 0.5, half_depth)
    add_box(vertices, 0.5 - beam_width, -0.5, -half_depth,
        0.5, 0.5, half_depth)
    add_box(vertices, -0.5 + beam_width, -0.5, -half_depth,
        0.5 - beam_width, -0.5 + rung_height, half_depth)
    add_box(vertices, -0.5 + beam_width, 0.5 - rung_height, -half_depth,
        0.5 - beam_width, 0.5, half_depth)
    add_box(vertices, -0.5 + beam_width, -rung_height * 0.5, -half_depth,
        0.5 - beam_width, rung_height * 0.5, half_depth)
    return vertices
end

function Geometry.build_primitive_vertices()
    return {
        Block = Geometry.build_cube_vertices(),
        Wedge = Geometry.build_wedge_vertices(),
        CornerWedge = Geometry.build_corner_wedge_vertices(),
        Cylinder = Geometry.build_cylinder_vertices(18, "x"),
        CylinderY = Geometry.build_cylinder_vertices(18, "y"),
        Ball = Geometry.build_sphere_vertices(16, 12),
        Truss = Geometry.build_truss_vertices(),
    }
end

return Geometry
