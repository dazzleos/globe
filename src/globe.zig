//! 3D Globe mathematics, sphere geometry, projection, raycasting,
//! and VideoCore IV GPU rendering pipeline.

const std = @import("std");
const vc4 = @import("vc4");
const shader = @import("shader");
const map_data = @import("map_data.zig");

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

/// Raycasts from screen coordinates (x, y) onto the 3D unit sphere.
/// Returns the geographic coordinates of the hit point, or null if the ray misses the sphere.
pub fn raycastSphere(screen_x: f32, screen_y: f32, vp_w: f32, vp_h: f32, fovy_rad: f32, distance: f32, yaw: f32, pitch: f32) ?map_data.Coord {
    if (vp_w <= 0 or vp_h <= 0) return null;
    const aspect = vp_w / vp_h;
    const tan_fov = @tan(fovy_rad * 0.5);

    // NDC coordinates (-1 to 1):
    const ndc_x = (2.0 * screen_x / vp_w) - 1.0;
    const ndc_y = 1.0 - (2.0 * screen_y / vp_h);

    // Camera space ray direction:
    const dx_cam = ndc_x * tan_fov * aspect;
    const dy_cam = ndc_y * tan_fov;
    const dz_cam = -1.0;
    const len = @sqrt(dx_cam * dx_cam + dy_cam * dy_cam + dz_cam * dz_cam);
    const d_cam = [3]f32{ dx_cam / len, dy_cam / len, dz_cam / len };

    // Camera origin in world space:
    const cam_world = [3]f32{ 0, 0, distance };

    // Ray-sphere intersection in camera space:
    // Sphere is at origin with radius 1.0.
    const b = cam_world[2] * d_cam[2]; // cam_world is [0, 0, d], so C · D = d * d_cam[2]
    const c = distance * distance - 1.0; // |C|^2 - R^2
    const disc = b * b - c;
    if (disc < 0) return null; // Missed sphere

    const t = -b - @sqrt(disc);
    if (t < 0) return null;

    // Hit point in camera space:
    const hit_cam = [3]f32{
        cam_world[0] + t * d_cam[0],
        cam_world[1] + t * d_cam[1],
        cam_world[2] + t * d_cam[2],
    };

    // Transform hit point back by inverse camera rotation (un-pitch, then un-yaw):
    // Pitch rotation was around X, yaw rotation was around Y.
    // Inverse pitch: rotate by -pitch around X.
    const cos_p = @cos(-pitch);
    const sin_p = @sin(-pitch);
    const hit_pitch = [3]f32{
        hit_cam[0],
        hit_cam[1] * cos_p - hit_cam[2] * sin_p,
        hit_cam[1] * sin_p + hit_cam[2] * cos_p,
    };

    // Inverse yaw: rotate by -yaw around Y.
    const cos_y = @cos(-yaw);
    const sin_y = @sin(-yaw);
    const hit_model = [3]f32{
        hit_pitch[0] * cos_y + hit_pitch[2] * sin_y,
        hit_pitch[1],
        -hit_pitch[0] * sin_y + hit_pitch[2] * cos_y,
    };

    return cartesianToLatLon(hit_model);
}

pub const Vertex = extern struct {
    pos: [3]f32,
    uv: [2]f32,
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

/// Generates a smooth UV sphere with `lat_segs` rings and `lon_segs` slices.
pub fn generateSphere(gpa: std.mem.Allocator, lat_segs: u32, lon_segs: u32) !Mesh {
    const nv = (lat_segs + 1) * (lon_segs + 1);
    const ni = lat_segs * lon_segs * 6;
    const vertices = try gpa.alloc(Vertex, nv);
    errdefer gpa.free(vertices);
    const indices = try gpa.alloc(u16, ni);
    errdefer gpa.free(indices);

    var vi: u32 = 0;
    for (0..lat_segs + 1) |y| {
        const v = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(lat_segs));
        const theta = v * std.math.pi; // 0 to pi (North pole to South pole)
        const sin_t = @sin(theta);
        const cos_t = @cos(theta);

        for (0..lon_segs + 1) |x| {
            const u = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(lon_segs));
            const phi = u * 2.0 * std.math.pi; // 0 to 2*pi
            const sin_p = @sin(phi);
            const cos_p = @cos(phi);

            // Unit sphere coordinates:
            const px = sin_t * sin_p;
            const py = cos_t;
            const pz = sin_t * cos_p;

            vertices[vi] = .{
                .pos = .{ px, py, pz },
                .uv = .{ u, v },
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

pub const texture_w = 512;
pub const texture_h = 256;

/// GPU rendering resources for the 3D Globe on Raspberry Pi VideoCore IV.
pub const GlobeGpu = struct {
    pipeline: shader.Pipeline,
    vbo: vc4.Bo,
    ibo: vc4.Bo,
    texture: vc4.Bo,
    vertex_count: u32,
    index_count: u32,

    pub fn init(gpa: std.mem.Allocator, dev: vc4.Device) !GlobeGpu {
        const program = shader.Program.decode(@embedFile("globe.shader")) catch unreachable;
        var pipeline = try shader.Pipeline.init(gpa, dev, program, .{
            .vertex_stride = @sizeOf(Vertex),
            .attributes = &.{
                .{ .location = 0, .offset = @offsetOf(Vertex, "pos") },
                .{ .location = 1, .offset = @offsetOf(Vertex, "uv") },
                .{ .location = 2, .offset = @offsetOf(Vertex, "normal") },
            },
            .cull = .back,
        });
        errdefer pipeline.deinit(dev);

        // Generate 3D sphere mesh: 40 rings x 80 slices = 3,200 quads
        const mesh = try generateSphere(gpa, 40, 80);
        defer mesh.deinit(gpa);

        const vbo = try dev.createBo(@intCast(mesh.vertices.len * @sizeOf(Vertex)));
        errdefer dev.destroyBo(vbo);
        const ibo = try dev.createBo(@intCast(mesh.indices.len * 2));
        errdefer dev.destroyBo(ibo);

        @memcpy(vbo.map[0 .. mesh.vertices.len * @sizeOf(Vertex)], std.mem.sliceAsBytes(mesh.vertices));
        @memcpy(ibo.map[0 .. mesh.indices.len * 2], std.mem.sliceAsBytes(mesh.indices));

        // Generate offline base map texture:
        var pixels: [texture_w * texture_h]u32 = undefined;
        map_data.renderBaseMap(&pixels, texture_w, texture_h);

        const texture = try dev.createBo(vc4.texture.imageSize(texture_w, texture_h));
        errdefer dev.destroyBo(texture);
        vc4.texture.upload(texture.map, &pixels, texture_w, texture_h);

        return .{
            .pipeline = pipeline,
            .vbo = vbo,
            .ibo = ibo,
            .texture = texture,
            .vertex_count = @intCast(mesh.vertices.len),
            .index_count = @intCast(mesh.indices.len),
        };
    }

    pub fn deinit(g: *GlobeGpu, dev: vc4.Device) void {
        g.pipeline.deinit(dev);
        dev.destroyBo(g.vbo);
        dev.destroyBo(g.ibo);
        dev.destroyBo(g.texture);
    }

    pub fn draw(
        g: *GlobeGpu,
        frame: *vc4.render.Frame,
        viewport: vc4.render.Viewport,
        scissor: ?vc4.render.Viewport,
        mvp_mat: Mat4,
        rot_mat: Mat4,
        sun_dir: [3]f32,
        day_night_on: bool,
        cam_pos: [3]f32,
        atmo_on: bool,
    ) !void {
        // Uniforms layout matches globe.zig shader:
        // mvp: [4]Vec4 (16 floats)
        // rotation: [3]Vec4 (12 floats)
        // sun: Vec4 (4 floats)
        // camera: Vec4 (4 floats)
        // options: Vec4 (4 floats)
        var uniforms: [40]f32 = undefined;
        uniforms[0..16].* = mvp_mat;

        // Rotation columns (columns 0, 1, 2, with w=0):
        uniforms[16..20].* = .{ rot_mat[0], rot_mat[1], rot_mat[2], 0 };
        uniforms[20..24].* = .{ rot_mat[4], rot_mat[5], rot_mat[6], 0 };
        uniforms[24..28].* = .{ rot_mat[8], rot_mat[9], rot_mat[10], 0 };

        // Sun vector & toggle:
        uniforms[28..32].* = .{ sun_dir[0], sun_dir[1], sun_dir[2], if (day_night_on) 1.0 else 0.0 };

        // Camera position & atmosphere toggle:
        uniforms[32..36].* = .{ cam_pos[0], cam_pos[1], cam_pos[2], if (atmo_on) 1.0 else 0.0 };

        // Options: texturing=1, spare=0
        uniforms[36..40].* = .{ 1.0, 0.0, 0.0, 0.0 };

        g.pipeline.setUniforms(std.mem.asBytes(&uniforms));
        try g.pipeline.draw(frame, .{
            .viewport = viewport,
            .scissor = scissor,
            .vertices = g.vbo.handle,
            .vertex_offset = 0,
            .count = g.index_count,
            .indices = .{ .handle = g.ibo.handle, .offset = 0, .max_index = g.vertex_count - 1 },
            .texture = .{ .handle = g.texture.handle, .config = .{ .width = texture_w, .height = texture_h } },
        });
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

test "sphere mesh generation and globe shader validation" {
    const mesh = try generateSphere(testing.allocator, 40, 80);
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 41 * 81), mesh.vertices.len);
    try testing.expectEqual(@as(usize, 40 * 80 * 6), mesh.indices.len);
    for (mesh.indices) |idx| try testing.expect(idx < mesh.vertices.len);

    const prog = try shader.Program.decode(@embedFile("globe.shader"));
    for ([_]vc4.compiler.Compiled{ prog.fs, prog.vs, prog.cs }) |c| {
        try vc4.qpu.validate(c.code(), c.stage, null);
    }
}
