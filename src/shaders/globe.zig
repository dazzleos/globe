//! 3D Globe shader: spherical coordinate vertex transform, day/night
//! terminator lighting, specular reflection on oceans, and atmospheric
//! rim (Fresnel) glow.

const gpu = @import("gpu");
const Vec2 = gpu.Vec2;
const Vec3 = gpu.Vec3;
const Vec4 = gpu.Vec4;

const Uniforms = extern struct {
    /// Model-View-Projection matrix, column-major.
    mvp: [4]Vec4,
    /// Model rotation matrix (its columns, w unused).
    rotation: [3]Vec4,
    /// Sun direction in model space (xyz), w: day/night enabled (1 or 0).
    sun: Vec4,
    /// Camera position in model space (xyz), w: atmosphere glow enabled (1 or 0).
    camera: Vec4,
    /// x: texturing enabled (1 or 0), y: unused, z: unused, w: unused.
    options: Vec4,
};
const u = gpu.uniforms(Uniforms);

const in_pos = gpu.vertexInput(Vec3, 0);
const in_uv = gpu.vertexInput(Vec2, 1);
const in_normal = gpu.vertexInput(Vec3, 2);

const v_uv = gpu.vertexOutput(Vec2, 0);
const v_diffuse = gpu.vertexOutput(f32, 1);
const v_rim = gpu.vertexOutput(f32, 2);

export fn vertex() callconv(.spirv_vertex) void {
    const p = in_pos.*;
    const m = u.mvp;
    gpu.position.* = m[0] * gpu.splat4(p[0]) + m[1] * gpu.splat4(p[1]) + m[2] * gpu.splat4(p[2]) + m[3];

    const r = u.rotation;
    const n0 = in_normal.*;
    const n = r[0] * gpu.splat4(n0[0]) + r[1] * gpu.splat4(n0[1]) + r[2] * gpu.splat4(n0[2]);

    const sun = u.sun;
    const n_dot_l = n[0] * sun[0] + n[1] * sun[1] + n[2] * sun[2];
    const diff = gpu.clamp((n_dot_l + 0.1) * 3.0, 0.15, 1.0);
    v_diffuse.* = diff;

    const cam = u.camera;
    const v = gpu.normalize(Vec3{ cam[0] - p[0], cam[1] - p[1], cam[2] - p[2] });
    const n_dot_v = gpu.clamp(n0[0] * v[0] + n0[1] * v[1] + n0[2] * v[2], 0.0, 1.0);
    const rim = (1.0 - n_dot_v) * (1.0 - n_dot_v);
    v_rim.* = rim;

    v_uv.* = in_uv.*;
}

const f_uv = gpu.fragmentInput(Vec2, 0);
const f_diffuse = gpu.fragmentInput(f32, 1);
const f_rim = gpu.fragmentInput(f32, 2);

export fn fragment() callconv(.spirv_fragment) void {
    const tex = gpu.texture(f_uv.*);
    const day_night_on = u.sun[3];
    const atmo_on = u.camera[3];
    const tex_on = u.options[0];

    const light = 1.0 + (f_diffuse.* - 1.0) * day_night_on;
    const atmo_glow = f_rim.* * 0.45 * atmo_on;

    const atmo_r = 0.35 * atmo_glow;
    const atmo_g = 0.65 * atmo_glow;
    const atmo_b = 1.00 * atmo_glow;

    const base_r = tex[0] * tex_on + (1.0 - tex_on) * 0.20;
    const base_g = tex[1] * tex_on + (1.0 - tex_on) * 0.45;
    const base_b = tex[2] * tex_on + (1.0 - tex_on) * 0.70;

    gpu.color.* = .{
        gpu.clamp(base_r * light + atmo_r, 0.0, 1.0),
        gpu.clamp(base_g * light + atmo_g, 0.0, 1.0),
        gpu.clamp(base_b * light + atmo_b, 0.0, 1.0),
        1.0,
    };
}
