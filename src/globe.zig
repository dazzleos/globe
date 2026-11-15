//! 3D Globe mathematics, sphere geometry, projection, raycasting,
//! and VideoCore IV GPU rendering pipeline.

const std = @import("std");
const vc4 = @import("vc4");
const shader = @import("shader");
const map_data = @import("map_data");

pub const Mat4 = [16]f32;

pub fn identity() Mat4 {
    return .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };
}

pub fn mul(a: Mat4, b: Mat4) Mat4 {
    var out: Mat4 = undefined;
    for (0..4) |col| {
        for (0..4) |row| {
            var sum: f32 = 0;
            for (0..4) |k| {
                sum += a[k * 4 + row] * b[col * 4 + k];
            }
            out[col * 4 + row] = sum;
        }
    }
    return out;
}

pub fn perspective(fovy_rad: f32, aspect: f32, near: f32, far: f32) Mat4 {
    const f = 1.0 / @tan(fovy_rad / 2.0);
    var m: Mat4 = @splat(0);
    m[0] = f / aspect;
    m[5] = f;
    m[10] = (far + near) / (near - far);
    m[11] = -1.0;
    m[14] = 2.0 * far * near / (near - far);
    return m;
}

pub fn translation(x: f32, y: f32, z: f32) Mat4 {
    var m = identity();
    m[12] = x;
    m[13] = y;
    m[14] = z;
    return m;
}

pub fn rotationX(a: f32) Mat4 {
    const c = @cos(a);
    const s = @sin(a);
    var m = identity();
    m[5] = c;
    m[6] = s;
    m[9] = -s;
    m[10] = c;
    return m;
}

pub fn rotationY(a: f32) Mat4 {
    const c = @cos(a);
    const s = @sin(a);
    var m = identity();
    m[0] = c;
    m[2] = -s;
    m[8] = s;
    m[10] = c;
    return m;
}

/// Converts geographic coordinates (lat, lon in degrees) to a 3D point on a sphere of radius `r`.
/// +Y is North Pole, -Y is South Pole.
/// +Z is (lat=0, lon=0) Prime Meridian at the Equator.
/// +X is (lat=0, lon=90) 90° East at the Equator.
pub fn latLonToCartesian(lat_deg: f32, lon_deg: f32, radius: f32) [3]f32 {
    const lat = lat_deg * (std.math.pi / 180.0);
    const lon = lon_deg * (std.math.pi / 180.0);
    const cos_lat = @cos(lat);
    return .{
        radius * cos_lat * @sin(lon),
        radius * @sin(lat),
        radius * cos_lat * @cos(lon),
    };
}

/// Converts a 3D Cartesian point to geographic coordinates (lat, lon in degrees).
pub fn cartesianToLatLon(p: [3]f32) map_data.Coord {
    const r = @sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]);
    if (r < 1e-6) return .{ .lat = 0, .lon = 0 };
    const lat_rad = std.math.asin(std.math.clamp(p[1] / r, -1.0, 1.0));
    const lon_rad = std.math.atan2(p[0], p[2]);
    return .{
        .lat = lat_rad * (180.0 / std.math.pi),
        .lon = lon_rad * (180.0 / std.math.pi),
    };
}

/// Projects a 3D model point to 2D screen coordinates (viewport pixel coords).
/// Returns null if the point is culled behind the camera or on the back hemisphere of the sphere.
pub fn project(point: [3]f32, mvp: Mat4, cam_pos: [3]f32, vp_w: f32, vp_h: f32) ?[2]f32 {
    // Check if the surface normal faces the camera (back-face culling for sphere):
    // For unit sphere, normal at point is normalize(point).
    const nx = point[0];
    const ny = point[1];
    const nz = point[2];
    const vx = cam_pos[0] - point[0];
    const vy = cam_pos[1] - point[1];
    const vz = cam_pos[2] - point[2];
    const dot = nx * vx + ny * vy + nz * vz;
    if (dot <= 0.0) return null; // Back hemisphere

    // Clip space transform:
    const x = point[0] * mvp[0] + point[1] * mvp[4] + point[2] * mvp[8] + mvp[12];
    const y = point[0] * mvp[1] + point[1] * mvp[5] + point[2] * mvp[9] + mvp[13];
    const w = point[0] * mvp[3] + point[1] * mvp[7] + point[2] * mvp[11] + mvp[15];
    if (w <= 0.001) return null;

    // NDC to screen:
    const ndc_x = x / w;
    const ndc_y = y / w;
    const sx = (ndc_x + 1.0) * 0.5 * vp_w;
    const sy = (1.0 - ndc_y) * 0.5 * vp_h;
    return .{ sx, sy };
}

/// Raycasts from screen coordinates (x, y) onto the 3D unit sphere in camera space.
/// When `clamp_to_horizon` is true, rays outside the sphere disk are clamped to the
/// closest point on the sphere's visible horizon rim.
pub fn raycastCameraSphere(
    screen_x: f32,
    screen_y: f32,
    vp_w: f32,
    vp_h: f32,
    fovy_rad: f32,
    distance: f32,
    clamp_to_horizon: bool,
) ?[3]f32 {
    if (vp_w <= 0 or vp_h <= 0 or distance <= 1.0) return null;
    const aspect = vp_w / vp_h;
    const tan_fov = @tan(fovy_rad * 0.5);

    const ndc_x = (2.0 * screen_x / vp_w) - 1.0;
    const ndc_y = 1.0 - (2.0 * screen_y / vp_h);

    var rx = ndc_x * tan_fov * aspect;
    var ry = ndc_y * tan_fov;
    var r2 = rx * rx + ry * ry;
    const max_r2 = 1.0 / (distance * distance - 1.0);

    if (r2 > max_r2) {
        if (!clamp_to_horizon) return null;
        const scale = @sqrt(max_r2 / r2);
        rx *= scale;
        ry *= scale;
        r2 = max_r2;
    }

    const disc = @max(0.0, 1.0 - r2 * (distance * distance - 1.0));
    const t = (distance - @sqrt(disc)) / (r2 + 1.0);
    return .{
        t * rx,
        t * ry,
        distance - t,
    };
}

/// Transforms a camera-space point on the sphere into model space by undoing
/// the camera's pitch (X) and yaw (Y) rotations.
pub fn cameraToModel(hit_cam: [3]f32, yaw: f32, pitch: f32) [3]f32 {
    const cos_p = @cos(-pitch);
    const sin_p = @sin(-pitch);
    const hit_pitch = [3]f32{
        hit_cam[0],
        hit_cam[1] * cos_p - hit_cam[2] * sin_p,
        hit_cam[1] * sin_p + hit_cam[2] * cos_p,
    };

    const cos_y = @cos(-yaw);
    const sin_y = @sin(-yaw);
    return .{
        hit_pitch[0] * cos_y + hit_pitch[2] * sin_y,
        hit_pitch[1],
        -hit_pitch[0] * sin_y + hit_pitch[2] * cos_y,
    };
}

/// Raycasts from screen coordinates (x, y) onto the 3D unit sphere.
/// Returns the geographic coordinates of the hit point, or null if the ray misses the sphere.
pub fn raycastSphere(screen_x: f32, screen_y: f32, vp_w: f32, vp_h: f32, fovy_rad: f32, distance: f32, yaw: f32, pitch: f32) ?map_data.Coord {
    const hit_cam = raycastCameraSphere(screen_x, screen_y, vp_w, vp_h, fovy_rad, distance, false) orelse return null;
    const hit_model = cameraToModel(hit_cam, yaw, pitch);
    return cartesianToLatLon(hit_model);
}

fn wrapAngle(a: f32) f32 {
    return @rem(a + std.math.pi, 2.0 * std.math.pi) - (if (a + std.math.pi >= 0) @as(f32, std.math.pi) else -std.math.pi);
}

/// Solves for the globe `yaw` and `pitch` that place the model-space unit vector
/// `anchor` at the camera-space unit vector `target_cam` under the cursor.
pub fn solveDragRotation(
    anchor: [3]f32,
    target_cam: [3]f32,
    cur_yaw: f32,
    cur_pitch: f32,
    max_pitch: f32,
) struct { yaw: f32, pitch: f32 } {
    const hx = target_cam[0];
    const hy = target_cam[1];
    const hz = target_cam[2];
    const r_yz = @sqrt(hy * hy + hz * hz);

    var pitch = cur_pitch;
    if (r_yz > 1e-5) {
        const alpha = std.math.atan2(hy, hz);
        const sin_val = std.math.clamp(anchor[1] / r_yz, -1.0, 1.0);
        const theta = std.math.asin(sin_val);
        const p1 = wrapAngle(theta - alpha);
        const p2 = wrapAngle((std.math.pi - theta) - alpha);
        const d1 = @abs(wrapAngle(p1 - cur_pitch));
        const d2 = @abs(wrapAngle(p2 - cur_pitch));
        const chosen = if (d1 <= d2) p1 else p2;
        pitch = std.math.clamp(chosen, -max_pitch, max_pitch);
    }

    const z1 = -hy * @sin(pitch) + hz * @cos(pitch);
    const horiz = @sqrt(anchor[0] * anchor[0] + anchor[2] * anchor[2]);
    var yaw = cur_yaw;
    if (horiz > 1e-5 and (hx * hx + z1 * z1) > 1e-8) {
        const lon = std.math.atan2(anchor[0], anchor[2]);
        const target_lon = std.math.atan2(hx, z1);
        yaw = cur_yaw + wrapAngle((target_lon - lon) - cur_yaw);
    }
    return .{ .yaw = yaw, .pitch = pitch };
}

pub const Vertex = extern struct {
    pos: [3]f32,
    color: [3]f32,
    normal: [3]f32,
};

pub const Mesh = struct {
    vertices: []Vertex,
    indices: []u16,

    pub fn deinit(m: Mesh, gpa: std.mem.Allocator) void {
        gpa.free(m.vertices);
        gpa.free(m.indices);
    }
};

fn argbToRgb(argb: u32) [3]f32 {
    const r = @as(f32, @floatFromInt((argb >> 16) & 0xff)) / 255.0;
    const g = @as(f32, @floatFromInt((argb >> 8) & 0xff)) / 255.0;
    const b = @as(f32, @floatFromInt(argb & 0xff)) / 255.0;
    return .{ r, g, b };
}

/// Generates a smooth UV sphere with `lat_segs` rings and `lon_segs` slices,
/// colored with the MapLibre ocean fill (`#D8F2FF`).
pub fn generateSphere(gpa: std.mem.Allocator, lat_segs: u32, lon_segs: u32) !Mesh {
    const nv = (lat_segs + 1) * (lon_segs + 1);
    const ni = lat_segs * lon_segs * 6;
    const vertices = try gpa.alloc(Vertex, nv);
    errdefer gpa.free(vertices);
    const indices = try gpa.alloc(u16, ni);
    errdefer gpa.free(indices);

    const ocean_rgb = argbToRgb(map_data.ocean_color);

    var vi: u32 = 0;
    for (0..lat_segs + 1) |y| {
        const v = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(lat_segs));
        const theta = v * std.math.pi; // 0 to pi (North pole to South pole)
        const sin_t = @sin(theta);
        const cos_t = @cos(theta);

        for (0..lon_segs + 1) |x| {
            const u = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(lon_segs));
            // u = 0 is -180° (-pi), u = 0.5 is 0° Prime Meridian (+Z), u = 1 is +180° (+pi).
            const phi = (u * 2.0 - 1.0) * std.math.pi;
            const sin_p = @sin(phi);
            const cos_p = @cos(phi);

            // Unit sphere coordinates:
            const px = sin_t * sin_p;
            const py = cos_t;
            const pz = sin_t * cos_p;

            vertices[vi] = .{
                .pos = .{ px, py, pz },
                .color = ocean_rgb,
                .normal = .{ px, py, pz },
            };
            vi += 1;
        }
    }

    var ii: u32 = 0;
    for (0..lat_segs) |y| {
        for (0..lon_segs) |x| {
            const row1 = @as(u16, @intCast(y * (lon_segs + 1) + x));
            const row2 = @as(u16, @intCast((y + 1) * (lon_segs + 1) + x));

            indices[ii] = row1;
            indices[ii + 1] = row2;
            indices[ii + 2] = row1 + 1;
            indices[ii + 3] = row1 + 1;
            indices[ii + 4] = row2;
            indices[ii + 5] = row2 + 1;
            ii += 6;
        }
    }

    return .{ .vertices = vertices, .indices = indices };
}

pub const DrawBatch = struct {
    vertex_offset: u32,
    vertex_count: u32,
    index_offset: u32,
    index_count: u32,
};

pub const BatchedMesh = struct {
    vertices: []Vertex,
    indices: []u16,
    batches: [16]DrawBatch = undefined,
    batch_count: usize = 0,

    pub fn deinit(m: BatchedMesh, gpa: std.mem.Allocator) void {
        gpa.free(m.vertices);
        gpa.free(m.indices);
    }
};

pub fn generateVectorGlobeBatchedMesh(
    gpa: std.mem.Allocator,
    country_verts: []const map_data.CountryVertex,
    country_idxs: []const u16,
    country_batches: []const map_data.MeshBatch,
) !BatchedMesh {
    const sphere = try generateSphere(gpa, 40, 80);
    defer sphere.deinit(gpa);

    const total_v = sphere.vertices.len + country_verts.len;
    const total_i = sphere.indices.len + country_idxs.len;

    const vertices = try gpa.alloc(Vertex, total_v);
    errdefer gpa.free(vertices);
    const indices = try gpa.alloc(u16, total_i);
    errdefer gpa.free(indices);

    // 1. Copy ocean sphere vertices and indices:
    @memcpy(vertices[0..sphere.vertices.len], sphere.vertices);
    @memcpy(indices[0..sphere.indices.len], sphere.indices);

    // 2. Append Natural Earth country vertices slightly above unit sphere (r = 1.003):
    for (country_verts, 0..) |cv, i| {
        const lat_deg = @as(f32, @floatFromInt(cv.lat_cd)) * 0.01;
        const lon_deg = @as(f32, @floatFromInt(cv.lon_cd)) * 0.01;
        const n = latLonToCartesian(lat_deg, lon_deg, 1.0);
        const pos = [3]f32{ n[0] * 1.003, n[1] * 1.003, n[2] * 1.003 };
        const palette_idx = @min(cv.color_idx, @as(u8, @intCast(map_data.country_palette.len - 1)));
        const rgb = argbToRgb(map_data.country_palette[palette_idx]);

        vertices[sphere.vertices.len + i] = .{
            .pos = pos,
            .color = rgb,
            .normal = n,
        };
    }

    // 3. Append country triangle indices per batch with consistent outward CCW winding:
    var bm = BatchedMesh{
        .vertices = vertices,
        .indices = indices,
        .batch_count = country_batches.len,
    };

    for (country_batches, 0..) |b, bi| {
        const is_first = (bi == 0);
        const idx_bias: u16 = if (is_first) @intCast(sphere.vertices.len) else 0;
        const v_abs_base: usize = sphere.vertices.len + @as(usize, b.vert_start);

        var out_ii: usize = sphere.indices.len + @as(usize, b.idx_start);
        var src_ii: usize = @as(usize, b.idx_start);
        const src_end: usize = src_ii + @as(usize, b.idx_count);
        while (src_ii + 2 < src_end) : (src_ii += 3) {
            const raw0 = country_idxs[src_ii];
            const raw1 = country_idxs[src_ii + 1];
            const raw2 = country_idxs[src_ii + 2];

            const p0 = vertices[v_abs_base + raw0].pos;
            const p1 = vertices[v_abs_base + raw1].pos;
            const p2 = vertices[v_abs_base + raw2].pos;

            const e1 = [3]f32{ p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2] };
            const e2 = [3]f32{ p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2] };
            const cx = e1[1] * e2[2] - e1[2] * e2[1];
            const cy = e1[2] * e2[0] - e1[0] * e2[2];
            const cz = e1[0] * e2[1] - e1[1] * e2[0];
            const dot = cx * p0[0] + cy * p0[1] + cz * p0[2];

            if (dot >= 0) {
                indices[out_ii] = idx_bias + raw0;
                indices[out_ii + 1] = idx_bias + raw1;
                indices[out_ii + 2] = idx_bias + raw2;
            } else {
                indices[out_ii] = idx_bias + raw0;
                indices[out_ii + 1] = idx_bias + raw2;
                indices[out_ii + 2] = idx_bias + raw1;
            }
            out_ii += 3;
        }

        if (is_first) {
            bm.batches[bi] = .{
                .vertex_offset = 0,
                .vertex_count = @intCast(sphere.vertices.len + @as(usize, b.vert_count)),
                .index_offset = 0,
                .index_count = @intCast(sphere.indices.len + @as(usize, b.idx_count)),
            };
        } else {
            bm.batches[bi] = .{
                .vertex_offset = @intCast(v_abs_base * @sizeOf(Vertex)),
                .vertex_count = b.vert_count,
                .index_offset = @intCast((sphere.indices.len + @as(usize, b.idx_start)) * 2),
                .index_count = b.idx_count,
            };
        }
    }

    return bm;
}

/// Generates the complete 3D vector globe mesh combining the ocean sphere
/// and all Natural Earth 110m country vector triangles.
pub fn generateVectorGlobeMesh(gpa: std.mem.Allocator) !Mesh {
    const bm = try generateVectorGlobeBatchedMesh(
        gpa,
        &map_data.country_vertices,
        &map_data.country_indices,
        &map_data.country_batches,
    );
    return .{ .vertices = bm.vertices, .indices = bm.indices };
}

/// Generates the high-detail 50m 3D vector globe mesh split into 16-bit index batches.
pub fn generateVectorGlobeMesh50m(gpa: std.mem.Allocator) !BatchedMesh {
    return generateVectorGlobeBatchedMesh(
        gpa,
        &map_data.country_50m_vertices,
        &map_data.country_50m_indices,
        &map_data.country_50m_batches,
    );
}

// --- The globe in cells -------------------------------------------------------

/// The globe's geometry in cells of latitude and longitude, so that only
/// what can be seen is drawn: a cell wholly behind the globe, or outside
/// the view, is left out (zoomed in, nearly all of them). Each cell has
/// its ocean, its land and its lines, drawn in three passes (all the
/// cells' ocean, then all their land, then all their lines), so a cell's
/// land never goes under its neighbour's ocean.
pub const Cell = struct {
    /// The middle of the cell (on the unit sphere), and how far (in
    /// radians) its furthest point is from it.
    center: [3]f32,
    angle: f32,
    /// Where its vertices start (bytes), and its triangles' indices
    /// (relative to them): the ocean's, then the land's.
    fill_vertices: u32 = 0,
    fill_max_index: u32 = 0,
    ocean: Range = .{},
    land: Range = .{},
    line_vertices: u32 = 0,
    line_max_index: u32 = 0,
    lines: Range = .{},
};

/// Indices in an index buffer: from `offset` (bytes), `count` of them.
pub const Range = struct { offset: u32 = 0, count: u32 = 0 };

/// A line vertex (see shaders/globe_lines.zig): its end of the segment,
/// the other end, and its side, end and style.
pub const LineVertex = extern struct {
    p: [3]f32,
    q: [3]f32,
    side: [3]f32,
};

/// The lines' styles, in shaders/globe_lines.zig's order: coastlines,
/// borders, the equator, the tropics, the polar circles. Their colours and
/// widths (pixels).
pub const LineStyle = enum(u8) { coast, border, equator, tropic, polar };
pub const line_colors = [5]u32{ map_data.coastline_color, map_data.boundary_color, 0xA8198EC8, 0x88198EC8, 0x70198EC8 };
pub const line_widths = [5]f32{ 1.2, 1.3, 1.3, 1.1, 1.0 };
/// Lines are drawn this far out (the land is at 1.003).
const line_radius = 1.004;

/// The globe's geometry at one detail, in cells.
pub const CellMesh = struct {
    fill_vertices: []Vertex,
    fill_indices: []u16,
    line_vertices: []LineVertex,
    line_indices: []u16,
    cells: []Cell,

    pub fn deinit(m: CellMesh, gpa: std.mem.Allocator) void {
        gpa.free(m.fill_vertices);
        gpa.free(m.fill_indices);
        gpa.free(m.line_vertices);
        gpa.free(m.line_indices);
        gpa.free(m.cells);
    }
};

/// How the globe is cut: rows of `lat_step` degrees, columns of `lon_step`.
pub const Grid = struct {
    lat_step: f32,
    lon_step: f32,

    fn rows(g: Grid) usize {
        return @intFromFloat(@ceil(180 / g.lat_step));
    }

    fn cols(g: Grid) usize {
        return @intFromFloat(@ceil(360 / g.lon_step));
    }

    fn count(g: Grid) usize {
        return g.rows() * g.cols();
    }

    /// The cell a point of the unit sphere is in.
    fn cellOf(g: Grid, p: [3]f32) usize {
        const ll = cartesianToLatLon(p);
        const r: usize = @intFromFloat(std.math.clamp(@floor((ll.lat + 90) / g.lat_step), 0, @as(f32, @floatFromInt(g.rows() - 1))));
        const c: usize = @intFromFloat(std.math.clamp(@floor((ll.lon + 180) / g.lon_step), 0, @as(f32, @floatFromInt(g.cols() - 1))));
        return r * g.cols() + c;
    }

    fn centerOf(g: Grid, cell: usize) [3]f32 {
        const r = cell / g.cols();
        const c = cell % g.cols();
        const lat = -90 + (@as(f32, @floatFromInt(r)) + 0.5) * g.lat_step;
        const lon = -180 + (@as(f32, @floatFromInt(c)) + 0.5) * g.lon_step;
        return latLonToCartesian(@min(lat, 89.9), lon, 1);
    }
};

/// Coarse far away (few cells, few draws), finer close up (most of them
/// out of sight).
pub const low_grid: Grid = .{ .lat_step = 30, .lon_step = 60 };
pub const high_grid: Grid = .{ .lat_step = 15, .lon_step = 30 };

fn unit(p: [3]f32) [3]f32 {
    const l = @sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]);
    return .{ p[0] / l, p[1] / l, p[2] / l };
}

fn dot3(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

/// A segment of a line, from `a` to `b` (on the unit sphere), in `style`.
const Segment = struct { a: [3]f32, b: [3]f32, style: LineStyle };

/// The globe's lines at this detail as segments: coastlines, borders,
/// the equator, and the tropics and polar circles (dashed).
fn lineSegments(gpa: std.mem.Allocator, high: bool) ![]Segment {
    var out: std.ArrayList(Segment) = .empty;
    errdefer out.deinit(gpa);
    const sets = [_]struct { []const [2]i16, []const map_data.LineSpan, LineStyle }{
        if (high) .{ &map_data.coastline_50m_points, &map_data.coastline_50m_spans, .coast } else .{ &map_data.coastline_points, &map_data.coastline_spans, .coast },
        if (high) .{ &map_data.border_50m_points, &map_data.border_50m_spans, .border } else .{ &map_data.border_points, &map_data.border_spans, .border },
    };
    for (sets) |set| for (set[1]) |sp| {
        const end = @min(@as(usize, sp.start) + sp.len, set[0].len);
        var prev: ?[3]f32 = null;
        for (set[0][sp.start..end]) |pt| {
            const p = latLonToCartesian(@as(f32, @floatFromInt(pt[1])) * 0.01, @as(f32, @floatFromInt(pt[0])) * 0.01, 1);
            if (prev) |a| try out.append(gpa, .{ .a = a, .b = p, .style = set[2] });
            prev = p;
        }
    };
    // The equator, every 2 degrees; the others dashed (4 degrees of every
    // 6).
    var lon: f32 = -180;
    while (lon < 180) : (lon += 2) try out.append(gpa, .{ .a = latLonToCartesian(0, lon, 1), .b = latLonToCartesian(0, lon + 2, 1), .style = .equator });
    for ([_]struct { f32, LineStyle }{ .{ 23.4368, .tropic }, .{ -23.4368, .tropic }, .{ 66.5632, .polar }, .{ -66.5632, .polar } }) |par| {
        var d: f32 = -180;
        while (d < 180) : (d += 6) {
            try out.append(gpa, .{ .a = latLonToCartesian(par[0], d, 1), .b = latLonToCartesian(par[0], d + 2, 1), .style = par[1] });
            try out.append(gpa, .{ .a = latLonToCartesian(par[0], d + 2, 1), .b = latLonToCartesian(par[0], d + 4, 1), .style = par[1] });
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The globe at this detail (`mesh`: the ocean sphere's triangles, the
/// first `ocean_indices` of its first batch, then the countries'), cut
/// into `grid`'s cells, with its lines.
pub fn cellMesh(gpa: std.mem.Allocator, mesh: BatchedMesh, ocean_indices: usize, high: bool, grid: Grid) !CellMesh {
    const n_cells = grid.count();
    // Every triangle (global vertex indices), the cell it is in, and
    // whether it is ocean.
    const Tri = struct { v: [3]u32, cell: u32, ocean: bool };
    var tris: std.ArrayList(Tri) = .empty;
    defer tris.deinit(gpa);
    for (mesh.batches[0..mesh.batch_count], 0..) |b, bi| {
        const base: u32 = b.vertex_offset / @sizeOf(Vertex);
        const first: usize = b.index_offset / 2;
        var i: usize = 0;
        while (i + 2 < b.index_count) : (i += 3) {
            var v: [3]u32 = undefined;
            for (&v, 0..) |*o, k| o.* = base + mesh.indices[first + i + k];
            const a = mesh.vertices[v[0]].normal;
            const bb = mesh.vertices[v[1]].normal;
            const c = mesh.vertices[v[2]].normal;
            const mid = unit(.{ a[0] + bb[0] + c[0], a[1] + bb[1] + c[1], a[2] + bb[2] + c[2] });
            try tris.append(gpa, .{ .v = v, .cell = @intCast(grid.cellOf(mid)), .ocean = bi == 0 and first + i < ocean_indices });
        }
    }
    const segments = try lineSegments(gpa, high);
    defer gpa.free(segments);

    const cells = try gpa.alloc(Cell, n_cells);
    errdefer gpa.free(cells);
    for (cells, 0..) |*c, i| c.* = .{ .center = grid.centerOf(i), .angle = 0 };
    var fill_vertices: std.ArrayList(Vertex) = .empty;
    errdefer fill_vertices.deinit(gpa);
    var fill_indices: std.ArrayList(u16) = .empty;
    errdefer fill_indices.deinit(gpa);
    var line_vertices: std.ArrayList(LineVertex) = .empty;
    errdefer line_vertices.deinit(gpa);
    var line_indices: std.ArrayList(u16) = .empty;
    errdefer line_indices.deinit(gpa);
    // Each source vertex's index in the cell being made (stamped with the
    // cell, so it need not be cleared between cells).
    const local = try gpa.alloc(u32, mesh.vertices.len);
    defer gpa.free(local);
    const stamp = try gpa.alloc(u32, mesh.vertices.len);
    defer gpa.free(stamp);
    @memset(stamp, std.math.maxInt(u32));

    // The triangles by cell (a stable sort keeps ocean before land: it
    // comes first in the source).
    std.mem.sort(Tri, tris.items, {}, struct {
        fn less(_: void, a: Tri, b: Tri) bool {
            if (a.cell != b.cell) return a.cell < b.cell;
            return a.ocean and !b.ocean;
        }
    }.less);
    var at: usize = 0;
    for (cells, 0..) |*cell, ci| {
        const vertex_base = fill_vertices.items.len;
        cell.fill_vertices = @intCast(vertex_base * @sizeOf(Vertex));
        var reach: f32 = 1;
        for ([_]bool{ true, false }) |ocean| {
            const range: *Range = if (ocean) &cell.ocean else &cell.land;
            range.offset = @intCast(fill_indices.items.len * 2);
            while (at < tris.items.len and tris.items[at].cell == ci and tris.items[at].ocean == ocean) : (at += 1) {
                for (tris.items[at].v) |gv| {
                    if (stamp[gv] != ci) {
                        stamp[gv] = @intCast(ci);
                        local[gv] = @intCast(fill_vertices.items.len - vertex_base);
                        const vert = mesh.vertices[gv];
                        try fill_vertices.append(gpa, vert);
                        reach = @min(reach, dot3(vert.normal, cell.center));
                    }
                    if (local[gv] > std.math.maxInt(u16)) return error.CellTooBig;
                    try fill_indices.append(gpa, @intCast(local[gv]));
                }
            }
            range.count = @intCast(fill_indices.items.len - range.offset / 2);
        }
        const fill_count = fill_vertices.items.len - vertex_base;
        cell.fill_max_index = @intCast(@max(fill_count, 1) - 1);
        // Its lines: the segments whose middle is in it.
        const line_base = line_vertices.items.len;
        cell.line_vertices = @intCast(line_base * @sizeOf(LineVertex));
        cell.lines.offset = @intCast(line_indices.items.len * 2);
        for (segments) |sg| {
            const mid = unit(.{ sg.a[0] + sg.b[0], sg.a[1] + sg.b[1], sg.a[2] + sg.b[2] });
            if (grid.cellOf(mid) != ci) continue;
            reach = @min(reach, dot3(sg.a, cell.center), dot3(sg.b, cell.center));
            const n: u16 = @intCast(line_vertices.items.len - line_base);
            if (@as(usize, n) + 4 > std.math.maxInt(u16)) return error.CellTooBig;
            const a: [3]f32 = .{ sg.a[0] * line_radius, sg.a[1] * line_radius, sg.a[2] * line_radius };
            const b: [3]f32 = .{ sg.b[0] * line_radius, sg.b[1] * line_radius, sg.b[2] * line_radius };
            const style: f32 = @floatFromInt(@intFromEnum(sg.style));
            // Side 1 and -1 at the first end, then at the other.
            try line_vertices.appendSlice(gpa, &.{
                .{ .p = a, .q = b, .side = .{ 1, 1, style } },
                .{ .p = a, .q = b, .side = .{ -1, 1, style } },
                .{ .p = b, .q = a, .side = .{ -1, -1, style } },
                .{ .p = b, .q = a, .side = .{ 1, -1, style } },
            });
            try line_indices.appendSlice(gpa, &.{ n, n + 1, n + 2, n, n + 2, n + 3 });
        }
        cell.lines.count = @intCast(line_indices.items.len - cell.lines.offset / 2);
        cell.line_max_index = @intCast(@max(line_vertices.items.len - line_base, 1) - 1);
        cell.angle = std.math.acos(std.math.clamp(reach, -1, 1)) + 0.002;
    }
    return .{
        .fill_vertices = try fill_vertices.toOwnedSlice(gpa),
        .fill_indices = try fill_indices.toOwnedSlice(gpa),
        .line_vertices = try line_vertices.toOwnedSlice(gpa),
        .line_indices = try line_indices.toOwnedSlice(gpa),
        .cells = cells,
    };
}

/// Whether `cell` can be seen: not wholly behind the globe from the
/// camera (`cam_model`, in model space), nor wholly outside the view
/// (`mvp`'s frustum).
pub fn cellVisible(cell: Cell, mvp: Mat4, cam_model: [3]f32) bool {
    const d = @sqrt(dot3(cam_model, cam_model));
    if (d <= 1) return true;
    const cam_dir: [3]f32 = .{ cam_model[0] / d, cam_model[1] / d, cam_model[2] / d };
    // Beyond the horizon: further round than it, by more than the cell's
    // size.
    const horizon = std.math.acos(@min(1.0, line_radius / d));
    const from_cam = std.math.acos(std.math.clamp(dot3(cell.center, cam_dir), -1, 1));
    if (from_cam - cell.angle > horizon) return false;
    // Outside the frustum: the cell's bounding sphere (round its middle,
    // as far as the chord to its furthest point) wholly beyond a plane.
    const r = 2 * @sin(cell.angle / 2) + 0.01;
    const c = cell.center;
    const m = mvp;
    for (0..3) |axis| {
        for ([_]f32{ 1, -1 }) |sign| {
            var plane: [4]f32 = undefined;
            for (0..4) |col| plane[col] = m[col * 4 + 3] + sign * m[col * 4 + axis];
            const len = @sqrt(plane[0] * plane[0] + plane[1] * plane[1] + plane[2] * plane[2]);
            if (len < 1e-6) continue;
            if ((plane[0] * c[0] + plane[1] * c[1] + plane[2] * c[2] + plane[3]) / len < -r) return false;
        }
    }
    return true;
}

/// One detail's buffers on the GPU.
const DetailGpu = struct {
    fill_vbo: vc4.Bo,
    fill_ibo: vc4.Bo,
    line_vbo: vc4.Bo,
    line_ibo: vc4.Bo,
    cells: []Cell,

    fn init(gpa: std.mem.Allocator, dev: vc4.Device, m: CellMesh) !DetailGpu {
        const fill_vbo = try dev.createBo(@intCast(@max(std.mem.sliceAsBytes(m.fill_vertices).len, 64)));
        errdefer dev.destroyBo(fill_vbo);
        const fill_ibo = try dev.createBo(@intCast(@max(std.mem.sliceAsBytes(m.fill_indices).len, 64)));
        errdefer dev.destroyBo(fill_ibo);
        const line_vbo = try dev.createBo(@intCast(@max(std.mem.sliceAsBytes(m.line_vertices).len, 64)));
        errdefer dev.destroyBo(line_vbo);
        const line_ibo = try dev.createBo(@intCast(@max(std.mem.sliceAsBytes(m.line_indices).len, 64)));
        errdefer dev.destroyBo(line_ibo);
        inline for (.{ .{ fill_vbo, m.fill_vertices }, .{ fill_ibo, m.fill_indices }, .{ line_vbo, m.line_vertices }, .{ line_ibo, m.line_indices } }) |pair| {
            const bytes = std.mem.sliceAsBytes(pair[1]);
            @memcpy(pair[0].map[0..bytes.len], bytes);
        }
        return .{ .fill_vbo = fill_vbo, .fill_ibo = fill_ibo, .line_vbo = line_vbo, .line_ibo = line_ibo, .cells = try gpa.dupe(Cell, m.cells) };
    }

    fn deinit(d: *DetailGpu, gpa: std.mem.Allocator, dev: vc4.Device) void {
        for ([_]vc4.Bo{ d.fill_vbo, d.fill_ibo, d.line_vbo, d.line_ibo }) |bo| dev.destroyBo(bo);
        gpa.free(d.cells);
    }
};

/// What the last frame drew of the globe, for the log.
pub const DrawStats = struct { cells: u32 = 0, draws: u32 = 0, triangles: u32 = 0 };

/// GPU rendering resources for the 3D Vector Globe on Raspberry Pi VideoCore IV.
pub const GlobeGpu = struct {
    gpa: std.mem.Allocator,
    pipeline: shader.Pipeline,
    lines: shader.Pipeline,
    low: DetailGpu,
    high: DetailGpu,
    stats: DrawStats = .{},

    pub fn init(gpa: std.mem.Allocator, dev: vc4.Device) !GlobeGpu {
        const program = shader.Program.decode(@embedFile("globe.shader")) catch unreachable;
        var pipeline = try shader.Pipeline.init(gpa, dev, program, .{
            .vertex_stride = @sizeOf(Vertex),
            .attributes = &.{
                .{ .location = 0, .offset = @offsetOf(Vertex, "pos") },
                .{ .location = 1, .offset = @offsetOf(Vertex, "color") },
                .{ .location = 2, .offset = @offsetOf(Vertex, "normal") },
            },
            .cull = .back,
        });
        errdefer pipeline.deinit(dev);
        var lines = try shader.Pipeline.init(gpa, dev, shader.Program.decode(@embedFile("globe_lines.shader")) catch unreachable, .{
            .vertex_stride = @sizeOf(LineVertex),
            .attributes = &.{
                .{ .location = 0, .offset = @offsetOf(LineVertex, "p") },
                .{ .location = 1, .offset = @offsetOf(LineVertex, "q") },
                .{ .location = 2, .offset = @offsetOf(LineVertex, "side") },
            },
        });
        errdefer lines.deinit(dev);

        const ocean = 40 * 80 * 6;
        var low = blk: {
            const mesh = try generateVectorGlobeBatchedMesh(gpa, &map_data.country_vertices, &map_data.country_indices, &map_data.country_batches);
            defer mesh.deinit(gpa);
            const cm = try cellMesh(gpa, mesh, ocean, false, low_grid);
            defer cm.deinit(gpa);
            break :blk try DetailGpu.init(gpa, dev, cm);
        };
        errdefer low.deinit(gpa, dev);
        var high = blk: {
            const mesh = try generateVectorGlobeMesh50m(gpa);
            defer mesh.deinit(gpa);
            const cm = try cellMesh(gpa, mesh, ocean, true, high_grid);
            defer cm.deinit(gpa);
            break :blk try DetailGpu.init(gpa, dev, cm);
        };
        errdefer high.deinit(gpa, dev);
        return .{ .gpa = gpa, .pipeline = pipeline, .lines = lines, .low = low, .high = high };
    }

    pub fn deinit(g: *GlobeGpu, dev: vc4.Device) void {
        g.pipeline.deinit(dev);
        g.lines.deinit(dev);
        g.low.deinit(g.gpa, dev);
        g.high.deinit(g.gpa, dev);
    }

    pub fn draw(
        g: *GlobeGpu,
        frame: *vc4.render.Frame,
        viewport: vc4.render.Viewport,
        scissor: ?vc4.render.Viewport,
        mvp_mat: Mat4,
        rot_mat: Mat4,
        sun_dir: [3]f32,
        cam_pos: [3]f32,
        high_detail: bool,
    ) !void {
        // Uniforms layout matches globe.zig shader:
        // mvp: [4]Vec4 (16 floats)
        // rotation: [3]Vec4 (12 floats)
        // sun: Vec4 (4 floats)
        // camera: Vec4 (4 floats)
        var uniforms: [36]f32 = undefined;
        uniforms[0..16].* = mvp_mat;
        uniforms[16..20].* = .{ rot_mat[0], rot_mat[1], rot_mat[2], 0 };
        uniforms[20..24].* = .{ rot_mat[4], rot_mat[5], rot_mat[6], 0 };
        uniforms[24..28].* = .{ rot_mat[8], rot_mat[9], rot_mat[10], 0 };
        uniforms[28..32].* = .{ sun_dir[0], sun_dir[1], sun_dir[2], 0.0 };
        uniforms[32..36].* = .{ cam_pos[0], cam_pos[1], cam_pos[2], 0.0 };
        g.pipeline.setUniforms(std.mem.asBytes(&uniforms));

        // The lines' (shaders/globe_lines.zig).
        var lu: [16 + 4 + 4 + 5 * 4 + 8]f32 = undefined;
        lu[0..16].* = mvp_mat;
        lu[16..20].* = .{ cam_pos[0], cam_pos[1], cam_pos[2], 0 };
        lu[20..24].* = .{ @as(f32, @floatFromInt(viewport.width)) / 2, @as(f32, @floatFromInt(viewport.height)) / 2, 0, 0 };
        for (line_colors, 0..) |c, i| lu[24 + i * 4 ..][0..4].* = .{
            @as(f32, @floatFromInt((c >> 16) & 0xff)) / 255,
            @as(f32, @floatFromInt((c >> 8) & 0xff)) / 255,
            @as(f32, @floatFromInt(c & 0xff)) / 255,
            @as(f32, @floatFromInt(c >> 24)) / 255,
        };
        lu[44..48].* = line_widths[0..4].*;
        lu[48..52].* = .{ line_widths[4], 0, 0, 0 };
        g.lines.setUniforms(std.mem.asBytes(&lu));

        const d = if (high_detail) &g.high else &g.low;
        var visible: [high_grid.rows() * high_grid.cols()]u16 = undefined;
        var n: usize = 0;
        for (d.cells, 0..) |c, i| if (cellVisible(c, mvp_mat, cam_pos)) {
            visible[n] = @intCast(i);
            n += 1;
        };
        g.stats = .{ .cells = @intCast(n) };
        // All the ocean, then all the land, then the lines.
        for (0..3) |pass| for (visible[0..n]) |i| {
            const c = d.cells[i];
            const range = switch (pass) {
                0 => c.ocean,
                1 => c.land,
                else => c.lines,
            };
            if (range.count == 0) continue;
            const lines_pass = pass == 2;
            try (if (lines_pass) &g.lines else &g.pipeline).draw(frame, .{
                .viewport = viewport,
                .scissor = scissor,
                .vertices = if (lines_pass) d.line_vbo.handle else d.fill_vbo.handle,
                .vertex_offset = if (lines_pass) c.line_vertices else c.fill_vertices,
                .count = range.count,
                .indices = .{
                    .handle = if (lines_pass) d.line_ibo.handle else d.fill_ibo.handle,
                    .offset = range.offset,
                    .max_index = if (lines_pass) c.line_max_index else c.fill_max_index,
                },
            });
            g.stats.draws += 1;
            g.stats.triangles += range.count / 3;
        };
    }
};

const testing = std.testing;

test "Cartesian and LatLon roundtrip" {
    const lat = 35.68;
    const lon = 139.65;
    const p = latLonToCartesian(lat, lon, 1.0);
    const back = cartesianToLatLon(p);
    try testing.expectApproxEqAbs(lat, back.lat, 1e-3);
    try testing.expectApproxEqAbs(lon, back.lon, 1e-3);
}

test "raycasting the sphere center" {
    // Click exactly at the center of viewport should hit (lat=0, lon=0) when unrotated
    const hit = raycastSphere(320.0, 240.0, 640.0, 480.0, 45.0 * (std.math.pi / 180.0), 2.5, 0.0, 0.0);
    try testing.expect(hit != null);
    try testing.expectApproxEqAbs(0.0, hit.?.lat, 1e-2);
    try testing.expectApproxEqAbs(0.0, hit.?.lon, 1e-2);
}

test "raycasting off the sphere" {
    // Click in outer corner of viewport should miss the sphere
    const hit = raycastSphere(10.0, 10.0, 640.0, 480.0, 45.0 * (std.math.pi / 180.0), 2.5, 0.0, 0.0);
    try testing.expect(hit == null);
}

test "solveDragRotation keeps the clicked point under the cursor" {
    const vp_w: f32 = 800.0;
    const vp_h: f32 = 600.0;
    const fovy: f32 = 45.0 * (std.math.pi / 180.0);
    const dist: f32 = 2.5;
    const init_yaw: f32 = 0.2;
    const init_pitch: f32 = 0.25;

    // Click at (350, 260) on the globe:
    const hit0 = raycastCameraSphere(350.0, 260.0, vp_w, vp_h, fovy, dist, false).?;
    const anchor = cameraToModel(hit0, init_yaw, init_pitch);

    // Drag to (460, 330):
    const hit1 = raycastCameraSphere(460.0, 330.0, vp_w, vp_h, fovy, dist, true).?;
    const rot = solveDragRotation(anchor, hit1, init_yaw, init_pitch, 1.45);

    // Verify that `anchor` now projects to (460, 330) on screen:
    const proj = perspective(fovy, vp_w / vp_h, 0.1, 20.0);
    const view = mul(translation(0, 0, -dist), mul(rotationX(rot.pitch), rotationY(rot.yaw)));
    const mvp = mul(proj, view);
    const cam_model = cameraToModel(.{ 0, 0, dist }, rot.yaw, rot.pitch);
    const scr = project(anchor, mvp, cam_model, vp_w, vp_h).?;
    try testing.expectApproxEqAbs(@as(f32, 460.0), scr[0], 0.05);
    try testing.expectApproxEqAbs(@as(f32, 330.0), scr[1], 0.05);
}

test "vector globe mesh generation and globe shader validation" {
    const mesh = try generateVectorGlobeMesh(testing.allocator);
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 41 * 81 + map_data.country_vertices.len), mesh.vertices.len);
    try testing.expectEqual(@as(usize, 40 * 80 * 6 + map_data.country_indices.len), mesh.indices.len);
    for (mesh.indices) |idx| try testing.expect(idx < mesh.vertices.len);

    // Equator at Prime Meridian (u = 0.5, v = 0.5 -> y = 20, x = 40) must be at +Z (0, 0, 1),
    // matching latLonToCartesian(0.0, 0.0, 1.0).
    const prime_eq = mesh.vertices[20 * 81 + 40];
    const expected = latLonToCartesian(0.0, 0.0, 1.0);
    try testing.expectApproxEqAbs(expected[0], prime_eq.pos[0], 1e-5);
    try testing.expectApproxEqAbs(expected[1], prime_eq.pos[1], 1e-5);
    try testing.expectApproxEqAbs(expected[2], prime_eq.pos[2], 1e-5);

    const mesh_50m = try generateVectorGlobeMesh50m(testing.allocator);
    defer mesh_50m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 41 * 81 + map_data.country_50m_vertices.len), mesh_50m.vertices.len);
    try testing.expectEqual(@as(usize, 40 * 80 * 6 + map_data.country_50m_indices.len), mesh_50m.indices.len);
    try testing.expect(mesh_50m.batch_count >= 1);
    for (mesh_50m.batches[0..mesh_50m.batch_count]) |b| {
        try testing.expect(b.vertex_count <= 65535);
        const i_start = b.index_offset / 2;
        for (mesh_50m.indices[i_start .. i_start + b.index_count]) |idx| {
            try testing.expect(idx < b.vertex_count);
        }
    }

    const prog = try shader.Program.decode(@embedFile("globe.shader"));
    for ([_]vc4.compiler.Compiled{ prog.fs, prog.vs, prog.cs }) |c| {
        try vc4.qpu.validate(c.code(), c.stage, null);
    }
}

test "the globe in cells: every triangle in one, each within its vertices, and only those in view drawn" {
    const gpa = testing.allocator;
    const ocean = 40 * 80 * 6;
    for ([_]bool{ false, true }) |high| {
        const mesh = if (high) try generateVectorGlobeMesh50m(gpa) else try generateVectorGlobeBatchedMesh(gpa, &map_data.country_vertices, &map_data.country_indices, &map_data.country_batches);
        defer mesh.deinit(gpa);
        const grid = if (high) high_grid else low_grid;
        const cm = try cellMesh(gpa, mesh, ocean, high, grid);
        defer cm.deinit(gpa);
        var source: usize = 0;
        for (mesh.batches[0..mesh.batch_count]) |b| source += b.index_count;
        var cut: usize = 0;
        var ocean_count: usize = 0;
        for (cm.cells) |c| {
            cut += c.ocean.count + c.land.count;
            ocean_count += c.ocean.count;
            const first = c.fill_vertices / @sizeOf(Vertex);
            for (cm.fill_indices[c.ocean.offset / 2 ..][0 .. c.ocean.count + c.land.count]) |i| {
                try testing.expect(i <= c.fill_max_index);
                try testing.expect(first + i < cm.fill_vertices.len);
            }
            for (cm.line_indices[c.lines.offset / 2 ..][0..c.lines.count]) |i| try testing.expect(i <= c.line_max_index);
        }
        try testing.expectEqual(source - source % 3, cut);
        try testing.expectEqual(@as(usize, ocean), ocean_count);
        try testing.expect(cm.line_indices.len > 0);
    }
    // From in front of +Z, far off: the cell facing it drawn, the one at
    // the back not; zoomed in, the cells far out of view not either.
    const proj = perspective(45.0 * (std.math.pi / 180.0), 16.0 / 9.0, 0.1, 20.0);
    const far = mul(proj, translation(0, 0, -2.5));
    const front: Cell = .{ .center = .{ 0, 0, 1 }, .angle = 0.3 };
    const back: Cell = .{ .center = .{ 0, 0, -1 }, .angle = 0.3 };
    const side: Cell = .{ .center = .{ 1, 0, 0 }, .angle = 0.1 };
    try testing.expect(cellVisible(front, far, .{ 0, 0, 2.5 }));
    try testing.expect(!cellVisible(back, far, .{ 0, 0, 2.5 }));
    const near = mul(proj, translation(0, 0, -1.2));
    try testing.expect(cellVisible(front, near, .{ 0, 0, 1.2 }));
    try testing.expect(!cellVisible(side, near, .{ 0, 0, 1.2 }));
}
