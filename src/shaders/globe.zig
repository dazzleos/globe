//! 3D Vector Globe shader: spherical coordinate vertex transform, per-vertex
//! political map colors, and subtle 3D limb shading.

const gpu = @import("gpu");
const Vec3 = gpu.Vec3;
const Vec4 = gpu.Vec4;

const Uniforms = extern struct {
    /// Model-View-Projection matrix, column-major.
    mvp: [4]Vec4,
    /// Model rotation matrix (its columns, w unused).
    rotation: [3]Vec4,
    /// Sun direction in model space (xyz), w: unused.
    sun: Vec4,
    /// Camera position in model space (xyz), w: unused.
    camera: Vec4,
};
const u = gpu.uniforms(Uniforms);

const in_pos = gpu.vertexInput(Vec3, 0);
const in_color = gpu.vertexInput(Vec3, 1);
const in_normal = gpu.vertexInput(Vec3, 2);

const v_color = gpu.vertexOutput(Vec3, 0);
const v_shade = gpu.vertexOutput(f32, 1);

export fn vertex() callconv(.spirv_vertex) void {
    const p = in_pos.*;
    const m = u.mvp;
    gpu.position.* = m[0] * gpu.splat4(p[0]) + m[1] * gpu.splat4(p[1]) + m[2] * gpu.splat4(p[2]) + m[3];

    const n0 = in_normal.*;
    const cam = u.camera;
    const v = gpu.normalize(Vec3{ cam[0] - p[0], cam[1] - p[1], cam[2] - p[2] });
    const n_dot_v = gpu.clamp(n0[0] * v[0] + n0[1] * v[1] + n0[2] * v[2], 0.0, 1.0);

    // Subtle spherical limb shading so the MapLibre political colors stay bright
    // and true while giving the globe gentle 3D curvature depth:
    v_shade.* = 0.88 + 0.12 * n_dot_v;
    v_color.* = in_color.*;
}

const f_color = gpu.fragmentInput(Vec3, 0);
const f_shade = gpu.fragmentInput(f32, 1);

export fn fragment() callconv(.{ .spirv_fragment = .{} }) void {
    const c = f_color.*;
    const s = f_shade.*;
    gpu.color.* = .{
        gpu.clamp(c[0] * s, 0.0, 1.0),
        gpu.clamp(c[1] * s, 0.0, 1.0),
        gpu.clamp(c[2] * s, 0.0, 1.0),
        1.0,
    };
}
