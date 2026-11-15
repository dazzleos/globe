//! The globe's lines (coastlines, borders, the equator, tropics and polar
//! circles), made once and drawn by the GPU as the globe turns: each
//! segment a quad, two triangles, widened across the screen by the vertex
//! shader, with its edges anti-aliased by the fragment shader. Lines on
//! the far side of the globe fade out at the limb, and segments wholly
//! behind it are moved off the screen.

const gpu = @import("gpu");
const Vec2 = gpu.Vec2;
const Vec3 = gpu.Vec3;
const Vec4 = gpu.Vec4;

pub const styles = 5;

const Uniforms = extern struct {
    /// Model-View-Projection matrix, column-major.
    mvp: [4]Vec4,
    /// The camera's position in model space (xyz).
    camera: Vec4,
    /// Half the viewport's width and height, in pixels (xy).
    half_viewport: Vec4,
    /// Each style's colour (straight RGBA).
    colors: [styles]Vec4,
    /// Each style's width in pixels (styles 0 to 3, then 4).
    widths: Vec4,
    widths2: Vec4,
};
const u = gpu.uniforms(Uniforms);

/// The vertex's end of the segment, and the other end.
const in_p = gpu.vertexInput(Vec3, 0);
const in_q = gpu.vertexInput(Vec3, 1);
/// x: which side of the line (1 or -1); y: which end (1 at the first, -1
/// at the other, whose `q` is the first); z: its style.
const in_side = gpu.vertexInput(Vec3, 2);

const v_color = gpu.vertexOutput(Vec4, 0);
/// Across the line: pixels from its middle (negative on the other side).
const v_across = gpu.vertexOutput(f32, 1);
/// Half its width, in pixels.
const v_half = gpu.vertexOutput(f32, 2);

fn clip(p: Vec3) Vec4 {
    const m = u.mvp;
    return m[0] * gpu.splat4(p[0]) + m[1] * gpu.splat4(p[1]) + m[2] * gpu.splat4(p[2]) + m[3];
}

export fn vertex() callconv(.spirv_vertex) void {
    const p = in_p.*;
    const q = in_q.*;
    const side = in_side.*;
    const style = side[2];

    var color = u.colors[0];
    var width = u.widths[0];
    if (style > 0.5) {
        color = u.colors[1];
        width = u.widths[1];
    }
    if (style > 1.5) {
        color = u.colors[2];
        width = u.widths[2];
    }
    if (style > 2.5) {
        color = u.colors[3];
        width = u.widths[3];
    }
    if (style > 3.5) {
        color = u.colors[4];
        width = u.widths2[0];
    }

    const cp = clip(p);
    const cq = clip(q);
    const hv = Vec2{ u.half_viewport[0], u.half_viewport[1] };
    // Along the line on the screen, and across it.
    const sp = Vec2{ cp[0] / cp[3], cp[1] / cp[3] } * hv;
    const sq = Vec2{ cq[0] / cq[3], cq[1] / cq[3] } * hv;
    const d = sq - sp;
    const len = @max(@sqrt(d[0] * d[0] + d[1] * d[1]), 0.0001);
    const across = Vec2{ -d[1] / len, d[0] / len };
    // A pixel more than half its width each way, for the fading edge.
    const half = width * 0.5;
    const reach = half + 1;
    const k = side[0] * side[1] * reach;
    var pos = cp;
    pos[0] += across[0] * k / hv[0] * cp[3];
    pos[1] += across[1] * k / hv[1] * cp[3];

    // Facing the camera: fully at the near side, fading at the limb.
    const cam = Vec3{ u.camera[0], u.camera[1], u.camera[2] };
    const fp = gpu.dot(p, cam - p);
    const fq = gpu.dot(q, cam - q);
    color[3] *= gpu.clamp(fp * 20, 0, 1);
    // Both ends behind the globe: off the screen, whole.
    if (fp < 0 and fq < 0) pos[0] = 4 * pos[3];

    gpu.position.* = pos;
    v_color.* = color;
    v_across.* = side[0] * reach;
    v_half.* = half;
}

const f_color = gpu.fragmentInput(Vec4, 0);
const f_across = gpu.fragmentInput(f32, 1);
const f_half = gpu.fragmentInput(f32, 2);

export fn fragment() callconv(.{ .spirv_fragment = .{} }) void {
    var c = f_color.*;
    // Covered fully within its width, fading over the pixel at its edge.
    c[3] *= gpu.clamp(f_half.* + 0.5 - @abs(f_across.*), 0, 1);
    gpu.color.* = c;
}
