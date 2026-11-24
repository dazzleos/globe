//! The Globe window, as widgets: a clean, interactive 3D political globe
//! rendered with Natural Earth vectors, MapLibre globe colors, country
//! boundaries, coastlines, and labels, with a top-right fullscreen toggle.

const std = @import("std");
const kete = @import("kete");
const kete_vc4 = @import("kete_vc4");
const gfx = kete.gfx;
const font = kete.font;
const vc4 = @import("vc4");
const map_data = @import("map_data");
const globe = @import("globe.zig");
const sys = @import("sys");

pub const min_size = [2]u32{ 640, 420 };
pub const open_size = [2]u32{ 1024, 680 };

pub const button_bg = gfx.Color.argb(0xd8182232);
pub const hud_text_color = gfx.Color.argb(0xffe8f0fa);
pub const label_color = gfx.Color.argb(0xff202834);
pub const label_halo_color = gfx.Color.argb(0xd8ffffff);
pub const geoline_label_color = gfx.Color.argb(0xff146c9c);
pub const detail_distance: f32 = 2.0;

/// What drawing the globe's overlays took since the app last took it
/// (`takeStats`), for the log: the time painting them, the points
/// projected (coastlines, borders, parallels) and the labels drawn.
pub const Stats = struct {
    paints: u32 = 0,
    paint_ns: u64 = 0,
    points: u64 = 0,
    labels: u64 = 0,
    high_detail: bool = false,
};
var stats: Stats = .{};

pub fn takeStats() Stats {
    defer stats = .{};
    return stats;
}

pub const Globe = struct {
    globe_gpu: ?*globe.GlobeGpu = null,
    /// Full screen or not (the window's own, if null).
    on_fullscreen: ?kete.Callback = null,
    fullscreen: bool = false,

    pub const State = struct {
        yaw: f32 = 0.2, // ~11° East (Europe/Africa centered initially)
        pitch: f32 = 0.25, // ~14° North
        distance: f32 = 2.5, // Space orbit view

        drag_vel_x: f32 = 0,
        drag_vel_y: f32 = 0,
        is_dragging: bool = false,
        drag_anchor: ?[3]f32 = null,
        last_pointer: ?[2]f32 = null,
        last_frame_ns: ?u64 = null,

        pub fn zoomIn(s: *State) void {
            s.distance = @max(s.distance * 0.88, 1.30);
        }

        pub fn zoomOut(s: *State) void {
            s.distance = @min(s.distance * 1.14, 4.8);
        }

        /// Two fingers `scale` times further apart: as much closer (the
        /// globe as much bigger), within the zooms the wheel goes to.
        pub fn pinch(s: *State, scale: f32) void {
            if (!(scale > 0)) return;
            s.distance = std.math.clamp(s.distance / scale, 1.30, 4.8);
        }
    };

    pub fn build(self: *const Globe, cx: *kete.BuildContext, state: *State) kete.Widget {
        const now = cx.now();
        const dt = if (state.last_frame_ns) |last|
            @as(f32, @floatFromInt(now -| last)) / @as(f32, @floatFromInt(std.time.ns_per_s))
        else
            0.016;
        state.last_frame_ns = now;

        // Smooth inertia after mouse release:
        if (!state.is_dragging) {
            if (@abs(state.drag_vel_x) > 0.001 or @abs(state.drag_vel_y) > 0.001) {
                state.yaw += state.drag_vel_x * dt;
                state.pitch = std.math.clamp(state.pitch + state.drag_vel_y * dt, -1.45, 1.45);
                state.drag_vel_x *= @exp(-dt * 5.0);
                state.drag_vel_y *= @exp(-dt * 5.0);
                cx.requestFrame();
            }
        }

        const window = cx.window();
        const is_fullscreen = self.fullscreen or (if (window) |w| w.isFullscreen() else false);
        const on_fullscreen = self.on_fullscreen orelse
            if (window) |w| kete.Callback.of(w, toggleFullscreen) else null;

        const a = cx.arena;
        var layers: std.ArrayList(kete.Widget) = .empty;

        // 1. 3D Political Vector Globe (fills background, clipped to bounds)
        layers.append(a, cx.make(GlobeView{
            .app = self,
            .state = state,
        })) catch {};

        // 2. Top-Right Fullscreen Toggle Button
        layers.append(a, cx.make(kete.Align{
            .alignment = .top_right,
            .child = cx.make(kete.Padding{
                .padding = .{ .top = 12, .right = 12 },
                .child = cx.make(kete.RoundedBox{
                    .color = button_bg,
                    .radius = kete.CornerRadii.all(20),
                    .child = cx.make(kete.IconButton{
                        .icon = if (is_fullscreen) .fullscreen_exit else .fullscreen,
                        .on_press = on_fullscreen,
                    }),
                }),
            }),
        })) catch {};

        // 3. Bottom-Left Coordinates & Altitude Overlay
        layers.append(a, cx.make(kete.Align{
            .alignment = .bottom_left,
            .child = cx.make(kete.Padding{
                .padding = .{ .left = 12, .bottom = 12 },
                .child = bottomHud(cx, state),
            }),
        })) catch {};

        return cx.make(kete.Overlay{ .children = layers.items });
    }

    fn toggleFullscreen(w: *kete.App.Window) void {
        w.setFullscreen(!w.isFullscreen());
    }

    fn bottomHud(cx: *kete.BuildContext, state: *const State) kete.Widget {
        const center_lat = state.pitch * (180.0 / std.math.pi);
        const center_lon = -state.yaw * (180.0 / std.math.pi);
        const alt_km = @as(u32, @intFromFloat(@max(state.distance - 1.0, 0.1) * 6371.0));

        const lat_str = if (center_lat >= 0)
            cx.fmt("{d:.1}° N", .{center_lat})
        else
            cx.fmt("{d:.1}° S", .{-center_lat});

        var lon_wrapped = center_lon;
        while (lon_wrapped > 180.0) lon_wrapped -= 360.0;
        while (lon_wrapped < -180.0) lon_wrapped += 360.0;
        const lon_str = if (lon_wrapped >= 0)
            cx.fmt("{d:.1}° E", .{lon_wrapped})
        else
            cx.fmt("{d:.1}° W", .{-lon_wrapped});

        const info = cx.fmt("{s}, {s}  ·  Altitude: {d} km", .{
            lat_str,
            lon_str,
            alt_km,
        });

        return cx.make(kete.RoundedBox{
            .color = button_bg,
            .radius = kete.CornerRadii.all(10),
            .child = cx.make(kete.Padding{
                .padding = .{ .left = 14, .right = 14, .top = 8, .bottom = 8 },
                .child = cx.make(kete.Text{
                    .text = info,
                    .style = .{ .size = 14, .color = hud_text_color },
                    .wrap = false,
                }),
            }),
        });
    }
};

/// Widget rendering the 3D Vector Globe and its coastline, boundary, and label overlays.
pub const GlobeView = struct {
    pub const clips_children = true;

    app: *const Globe,
    state: *Globe.State,

    pub fn layout(self: *const GlobeView, _: *kete.WidgetNode, c: kete.Constraints) kete.Size {
        _ = self;
        return c.biggest();
    }

    pub fn paint(self: *const GlobeView, n: *kete.WidgetNode, p: *kete.Painter) void {
        const w = n.size.w;
        const h = n.size.h;
        if (w <= 1 or h <= 1) return;

        // 1. Background canvas (rendered BEFORE the 3D GPU globe). Space is
        // the window's clear colour; round the globe, a glow: rings (only
        // they show, round its edge), and none once they are off the
        // screen (zoomed in).
        const bg_c = p.canvas();
        const fovy = 45.0 * (std.math.pi / 180.0);
        const tan_fov = @tan(fovy * 0.5);
        const sphere_screen_r = (h * 0.5) / (tan_fov * self.state.distance);
        const center_x = w * 0.5;
        const center_y = h * 0.5;
        const corner = @sqrt(center_x * center_x + center_y * center_y);

        if (sphere_screen_r > 5 and sphere_screen_r < corner) {
            glowRing(bg_c, .{ center_x, center_y }, sphere_screen_r, sphere_screen_r * 1.035, gfx.Color.argb(0x1868b8f8));
            glowRing(bg_c, .{ center_x, center_y }, sphere_screen_r, sphere_screen_r * 1.015, gfx.Color.argb(0x2890d4ff));
        }

        // 2. 3D GPU Vector Globe (Ocean sphere + Natural Earth country polygons):
        if (self.app.globe_gpu) |_| {
            var key = std.hash.Wyhash.init(0);
            key.update(std.mem.asBytes(&self.state.yaw));
            key.update(std.mem.asBytes(&self.state.pitch));
            key.update(std.mem.asBytes(&self.state.distance));

            p.gpuWith(.{ .key = key.final() }, self, drawGlobe);
        } else {
            // Software fallback circle for headless host tests without GPU:
            if (sphere_screen_r > 5) {
                bg_c.fillCircle(.{ center_x, center_y }, sphere_screen_r, gfx.Color.argb(map_data.ocean_color));
            }
        }

        // 3. Foreground overlay canvas (acquired AFTER p.gpuWith so coastlines,
        // borders, and country labels render ON TOP of the 3D GPU globe):
        const fg_c = p.canvas();
        const started = sys.nowNs();
        self.paintOverlays(w, h, fg_c, p);
        stats.paints += 1;
        stats.paint_ns += sys.nowNs() - started;
        stats.high_detail = self.state.distance <= detail_distance;
    }

    /// A ring round the globe, from `inner` to `outer` (radii, in pixels):
    /// a polygon with a hole, whose triangles cover only the ring. (A
    /// circle is drawn over its whole bounding square, shaded at every
    /// pixel: bigger than the screen, zoomed in, twice over.)
    fn glowRing(c: *gfx.Canvas, center: gfx.Point, inner: f32, outer: f32, color: gfx.Color) void {
        const n = 160;
        var out_pts: [n]gfx.Point = undefined;
        var in_pts: [n]gfx.Point = undefined;
        for (0..n) |i| {
            const a = @as(f32, @floatFromInt(i)) * (2 * std.math.pi / @as(f32, n));
            out_pts[i] = .{ center[0] + @cos(a) * outer, center[1] + @sin(a) * outer };
            in_pts[i] = .{ center[0] + @cos(a) * inner, center[1] + @sin(a) * inner };
        }
        c.fillPath(&.{ &out_pts, &in_pts }, color);
    }

    fn drawGlobe(self: *const GlobeView, frame: *vc4.render.Frame, area: kete.gfx.GpuArea) anyerror!void {
        const vp = kete_vc4.renderer.viewport(area.viewport);
        const aspect = @as(f32, @floatFromInt(vp.width)) / @as(f32, @floatFromInt(@max(vp.height, 1)));
        const proj = globe.perspective(45.0 * (std.math.pi / 180.0), aspect, 0.1, 20.0);
        const view_trans = globe.translation(0, 0, -self.state.distance);
        const rot_x = globe.rotationX(self.state.pitch);
        const rot_y = globe.rotationY(self.state.yaw);
        const rot = globe.mul(rot_x, rot_y);
        const view = globe.mul(view_trans, rot);
        const mvp = globe.mul(proj, view);

        // Camera position in model space for view-dependent limb shading:
        const cos_p = @cos(-self.state.pitch);
        const sin_p = @sin(-self.state.pitch);
        const d = self.state.distance;
        const eye_pitch = [3]f32{ 0, -d * sin_p, d * cos_p };
        const cos_y = @cos(-self.state.yaw);
        const sin_y = @sin(-self.state.yaw);
        const cam_model = [3]f32{
            eye_pitch[0] * cos_y + eye_pitch[2] * sin_y,
            eye_pitch[1],
            -eye_pitch[0] * sin_y + eye_pitch[2] * cos_y,
        };

        const sun_dir = [3]f32{ -0.4, 0.3, 0.85 };

        try self.app.globe_gpu.?.draw(
            frame,
            vp,
            if (area.scissor) |sc| kete_vc4.renderer.viewport(sc) else null,
            mvp,
            rot,
            sun_dir,
            cam_model,
            self.state.distance <= detail_distance,
        );
    }

    fn paintOverlays(self: *const GlobeView, w: f32, h: f32, c: *gfx.Canvas, p: *kete.Painter) void {
        const aspect = w / h;
        const proj = globe.perspective(45.0 * (std.math.pi / 180.0), aspect, 0.1, 20.0);
        const view_trans = globe.translation(0, 0, -self.state.distance);
        const rot_x = globe.rotationX(self.state.pitch);
        const rot_y = globe.rotationY(self.state.yaw);
        const rot = globe.mul(rot_x, rot_y);
        const view = globe.mul(view_trans, rot);
        const mvp = globe.mul(proj, view);

        // Camera position in model space:
        const cos_p = @cos(-self.state.pitch);
        const sin_p = @sin(-self.state.pitch);
        const d = self.state.distance;
        const eye_pitch = [3]f32{ 0, -d * sin_p, d * cos_p };
        const cos_y = @cos(-self.state.yaw);
        const sin_y = @sin(-self.state.yaw);
        const cam_model = [3]f32{
            eye_pitch[0] * cos_y + eye_pitch[2] * sin_y,
            eye_pitch[1],
            -eye_pitch[0] * sin_y + eye_pitch[2] * cos_y,
        };

        const high_detail = self.state.distance <= detail_distance;

        // 1. In CPU-only preview mode (no GPU), draw 2D projected country polygons
        // so unit tests and CPU previews show the political map as well:
        if (self.app.globe_gpu == null) {
            const verts = if (high_detail) &map_data.country_50m_vertices else &map_data.country_vertices;
            const idxs = if (high_detail) &map_data.country_50m_indices else &map_data.country_indices;
            const batches = if (high_detail) &map_data.country_50m_batches else &map_data.country_batches;
            for (batches) |b| {
                var ii: usize = b.idx_start;
                const i_end: usize = ii + b.idx_count;
                while (ii + 2 < i_end) : (ii += 3) {
                    const v0 = verts[b.vert_start + idxs[ii]];
                    const v1 = verts[b.vert_start + idxs[ii + 1]];
                    const v2 = verts[b.vert_start + idxs[ii + 2]];

                    const p0 = globe.latLonToCartesian(@as(f32, @floatFromInt(v0.lat_cd)) * 0.01, @as(f32, @floatFromInt(v0.lon_cd)) * 0.01, 1.0);
                    const p1 = globe.latLonToCartesian(@as(f32, @floatFromInt(v1.lat_cd)) * 0.01, @as(f32, @floatFromInt(v1.lon_cd)) * 0.01, 1.0);
                    const p2 = globe.latLonToCartesian(@as(f32, @floatFromInt(v2.lat_cd)) * 0.01, @as(f32, @floatFromInt(v2.lon_cd)) * 0.01, 1.0);

                    if (globe.project(p0, mvp, cam_model, w, h)) |s0| {
                        if (globe.project(p1, mvp, cam_model, w, h)) |s1| {
                            if (globe.project(p2, mvp, cam_model, w, h)) |s2| {
                                const pidx = @min(v0.color_idx, @as(u8, @intCast(map_data.country_palette.len - 1)));
                                const col = gfx.Color.argb(map_data.country_palette[pidx]);
                                c.fillPolygon(&.{ .{ s0[0], s0[1] }, .{ s1[0], s1[1] }, .{ s2[0], s2[1] } }, col);
                            }
                        }
                    }
                }
            }
        }

        // 2. Coastlines (#198EC8 from MapLibre globe style), borders and the
        // parallels: drawn by the GPU with the globe, when there is one
        // (see shaders/globe_lines.zig); here otherwise.
        if (self.app.globe_gpu == null) self.paintLines(w, h, c, mvp, cam_model, high_detail);
        self.paintLabels(w, h, p, mvp, cam_model);
    }

    fn paintLines(_: *const GlobeView, w: f32, h: f32, c: *gfx.Canvas, mvp: globe.Mat4, cam_model: [3]f32, high_detail: bool) void {
        const coast_col = gfx.Color.argb(map_data.coastline_color);
        if (high_detail) {
            drawProjectedSpans(c, &map_data.coastline_50m_points, &map_data.coastline_50m_spans, mvp, cam_model, w, h, 1.2, coast_col);
        } else {
            drawProjectedSpans(c, &map_data.coastline_points, &map_data.coastline_spans, mvp, cam_model, w, h, 1.2, coast_col);
        }

        // 3. International Country Boundaries (#FFFFFF from MapLibre globe style):
        const border_col = gfx.Color.argb(map_data.boundary_color);
        if (high_detail) {
            drawProjectedSpans(c, &map_data.border_50m_points, &map_data.border_50m_spans, mvp, cam_model, w, h, 1.3, border_col);
        } else {
            drawProjectedSpans(c, &map_data.border_points, &map_data.border_spans, mvp, cam_model, w, h, 1.3, border_col);
        }

        // 4. Equator, Tropics, and Polar Circles (MapLibre geolines style):
        drawParallel(c, 0.0, false, 1.3, gfx.Color.argb(0xA8198EC8), mvp, cam_model, w, h);
        drawParallel(c, 23.4368, true, 1.1, gfx.Color.argb(0x88198EC8), mvp, cam_model, w, h);
        drawParallel(c, -23.4368, true, 1.1, gfx.Color.argb(0x88198EC8), mvp, cam_model, w, h);
        drawParallel(c, 66.5632, true, 1.0, gfx.Color.argb(0x70198EC8), mvp, cam_model, w, h);
        drawParallel(c, -66.5632, true, 1.0, gfx.Color.argb(0x70198EC8), mvp, cam_model, w, h);
    }

    fn paintLabels(self: *const GlobeView, w: f32, h: f32, p: *kete.Painter, mvp: globe.Mat4, cam_model: [3]f32) void {
        const high_detail = self.state.distance <= detail_distance;
        // 5. Country & Geoline Labels (decluttered by zoom level and screen-space bounding boxes):
        const max_rank: u8 = if (self.state.distance > 3.0)
            2
        else if (self.state.distance > 2.2)
            3
        else if (self.state.distance > 1.7)
            4
        else
            6;

        const norm_cam_len = @sqrt(cam_model[0] * cam_model[0] + cam_model[1] * cam_model[1] + cam_model[2] * cam_model[2]);
        const inv_cam_len = if (norm_cam_len > 1e-4) 1.0 / norm_cam_len else 1.0;
        const cam_dir = [3]f32{
            cam_model[0] * inv_cam_len,
            cam_model[1] * inv_cam_len,
            cam_model[2] * inv_cam_len,
        };

        var placed_boxes: [64]gfx.Rect = undefined;
        var placed_count: usize = 0;

        // Place Equator and Tropics labels near the central meridian:
        const center_lon = -self.state.yaw * (180.0 / std.math.pi);
        const GeolineLabel = struct { name: []const u8, lat: f32 };
        for ([_]GeolineLabel{
            .{ .name = "Equator", .lat = 0.0 },
            .{ .name = "Tropic of Cancer", .lat = 23.4368 },
            .{ .name = "Tropic of Capricorn", .lat = -23.4368 },
        }) |gl| {
            const p3 = globe.latLonToCartesian(gl.lat, center_lon, 1.004);
            const facing = p3[0] * cam_dir[0] + p3[1] * cam_dir[1] + p3[2] * cam_dir[2];
            if (facing < 0.45) continue;
            if (globe.project(p3, mvp, cam_model, w, h)) |scr| {
                const f = p.ui.font orelse continue;
                const font_size: f32 = 10.5;
                const style: font.Style = .{ .font = f, .size = font_size };
                const text_w = p.ui.atlas.runs.measure(style, gl.name);
                const text_h = style.lineHeight();
                const lx = scr[0] - text_w * 0.5;
                const ly = scr[1] - text_h - 2.0;
                const box = gfx.Rect{ .x = lx - 4, .y = ly - 2, .w = text_w + 8, .h = text_h + 4 };
                if (box.x < 8 or box.y < 8 or box.x + box.w > w - 8 or box.y + box.h > h - 8) continue;
                placed_boxes[placed_count] = box;
                placed_count += 1;
                const baseline_y = ly + style.ascent();
                _ = p.text(font_size, lx - 1, baseline_y, gl.name, label_halo_color);
                _ = p.text(font_size, lx + 1, baseline_y, gl.name, label_halo_color);
                _ = p.text(font_size, lx, baseline_y - 1, gl.name, label_halo_color);
                _ = p.text(font_size, lx, baseline_y + 1, gl.name, label_halo_color);
                _ = p.text(font_size, lx, baseline_y, gl.name, geoline_label_color);
            }
        }

        const labels = if (high_detail) &map_data.country_50m_labels else &map_data.country_labels;
        for (labels) |lbl| {
            if (lbl.rank > max_rank) continue;
            if (placed_count >= placed_boxes.len) break;

            const p3 = globe.latLonToCartesian(lbl.lat, lbl.lon, 1.004);
            // Skip labels near the limb where text would look foreshortened:
            const facing = p3[0] * cam_dir[0] + p3[1] * cam_dir[1] + p3[2] * cam_dir[2];
            if (facing < 0.32) continue;

            if (globe.project(p3, mvp, cam_model, w, h)) |scr| {
                const f = p.ui.font orelse continue;
                const font_size: f32 = if (lbl.rank <= 2) 13.0 else if (lbl.rank == 3) 11.5 else 10.5;
                const style: font.Style = .{ .font = f, .size = font_size };
                const text_w = p.ui.atlas.runs.measure(style, lbl.name);
                const text_h = style.lineHeight();
                const lx = scr[0] - text_w * 0.5;
                const ly = scr[1] - text_h * 0.5;
                const box = gfx.Rect{
                    .x = lx - 6,
                    .y = ly - 3,
                    .w = text_w + 12,
                    .h = text_h + 6,
                };

                // Keep labels inside viewport margins:
                if (box.x < 8 or box.y < 8 or box.x + box.w > w - 8 or box.y + box.h > h - 8) continue;

                // Screen-space collision check to prevent overlapping country names:
                var overlaps = false;
                for (placed_boxes[0..placed_count]) |other| {
                    if (box.x < other.x + other.w and box.x + box.w > other.x and
                        box.y < other.y + other.h and box.y + box.h > other.y)
                    {
                        overlaps = true;
                        break;
                    }
                }
                if (overlaps) continue;

                placed_boxes[placed_count] = box;
                placed_count += 1;

                const baseline_y = ly + style.ascent();
                stats.labels += 1;
                // Crisp white halo behind dark label text:
                _ = p.text(font_size, lx - 1, baseline_y, lbl.name, label_halo_color);
                _ = p.text(font_size, lx + 1, baseline_y, lbl.name, label_halo_color);
                _ = p.text(font_size, lx, baseline_y - 1, lbl.name, label_halo_color);
                _ = p.text(font_size, lx, baseline_y + 1, lbl.name, label_halo_color);
                _ = p.text(font_size, lx, baseline_y, lbl.name, label_color);
            }
        }
    }

    fn drawProjectedSpans(
        c: *gfx.Canvas,
        points: []const [2]i16,
        spans: []const map_data.LineSpan,
        mvp: globe.Mat4,
        cam_model: [3]f32,
        w: f32,
        h: f32,
        thickness: f32,
        color: gfx.Color,
    ) void {
        var pts: [128]gfx.Point = undefined;
        for (spans) |sp| stats.points += sp.len;
        for (spans) |sp| {
            var count: usize = 0;
            const end = @min(@as(usize, sp.start) + @as(usize, sp.len), points.len);
            for (points[sp.start..end]) |pt| {
                const lon = @as(f32, @floatFromInt(pt[0])) * 0.01;
                const lat = @as(f32, @floatFromInt(pt[1])) * 0.01;
                const p3 = globe.latLonToCartesian(lat, lon, 1.004);
                if (globe.project(p3, mvp, cam_model, w, h)) |scr| {
                    if (count == pts.len) {
                        c.strokePolyline(pts[0..count], false, thickness, color);
                        pts[0] = pts[count - 1];
                        count = 1;
                    }
                    pts[count] = .{ scr[0], scr[1] };
                    count += 1;
                } else {
                    if (count >= 2) {
                        c.strokePolyline(pts[0..count], false, thickness, color);
                    }
                    count = 0;
                }
            }
            if (count >= 2) {
                c.strokePolyline(pts[0..count], false, thickness, color);
            }
        }
    }

    fn drawParallel(
        c: *gfx.Canvas,
        lat: f32,
        dashed: bool,
        thickness: f32,
        color: gfx.Color,
        mvp: globe.Mat4,
        cam_model: [3]f32,
        w: f32,
        h: f32,
    ) void {
        if (dashed) {
            // 4° dash, 2° gap around the parallel (60 dashes of 4° each):
            var seg: u32 = 0;
            while (seg < 60) : (seg += 1) {
                const lon0 = @as(f32, @floatFromInt(seg * 6)) - 180.0;
                const lon1 = lon0 + 2.0;
                const lon2 = lon0 + 4.0;
                const s0 = globe.project(globe.latLonToCartesian(lat, lon0, 1.0035), mvp, cam_model, w, h) orelse continue;
                const s1 = globe.project(globe.latLonToCartesian(lat, lon1, 1.0035), mvp, cam_model, w, h) orelse continue;
                const s2 = globe.project(globe.latLonToCartesian(lat, lon2, 1.0035), mvp, cam_model, w, h) orelse continue;
                c.strokePolyline(&.{ .{ s0[0], s0[1] }, .{ s1[0], s1[1] }, .{ s2[0], s2[1] } }, false, thickness, color);
            }
        } else {
            var pts: [181]gfx.Point = undefined;
            var count: usize = 0;
            var i: u32 = 0;
            while (i <= 180) : (i += 1) {
                const lon = @as(f32, @floatFromInt(i * 2)) - 180.0;
                const p3 = globe.latLonToCartesian(lat, lon, 1.0035);
                if (globe.project(p3, mvp, cam_model, w, h)) |scr| {
                    pts[count] = .{ scr[0], scr[1] };
                    count += 1;
                } else {
                    if (count >= 2) c.strokePolyline(pts[0..count], false, thickness, color);
                    count = 0;
                }
            }
            if (count >= 2) c.strokePolyline(pts[0..count], false, thickness, color);
        }
    }

    pub fn event(self: *const GlobeView, n: *kete.WidgetNode, e: kete.Event) bool {
        switch (e) {
            .press => |pr| {
                if (pr.button == .left) {
                    const fovy = 45.0 * (std.math.pi / 180.0);
                    if (globe.raycastCameraSphere(pr.pos[0], pr.pos[1], n.size.w, n.size.h, fovy, self.state.distance, false)) |hit_cam| {
                        self.state.drag_anchor = globe.cameraToModel(hit_cam, self.state.yaw, self.state.pitch);
                    } else {
                        self.state.drag_anchor = null;
                    }
                    self.state.is_dragging = true;
                    self.state.last_pointer = pr.pos;
                    self.state.drag_vel_x = 0;
                    self.state.drag_vel_y = 0;
                    n.ui.needs_frame = true;
                    return true;
                }
            },
            .motion => |pos| {
                if (self.state.is_dragging) {
                    const fovy = 45.0 * (std.math.pi / 180.0);
                    if (self.state.drag_anchor) |anchor| {
                        if (globe.raycastCameraSphere(pos[0], pos[1], n.size.w, n.size.h, fovy, self.state.distance, true)) |target_cam| {
                            const rot = globe.solveDragRotation(anchor, target_cam, self.state.yaw, self.state.pitch, 1.45);
                            self.state.yaw = rot.yaw;
                            self.state.pitch = rot.pitch;
                        }
                    } else if (self.state.last_pointer) |last| {
                        const dx = pos[0] - last[0];
                        const dy = pos[1] - last[1];

                        const sens = (self.state.distance / 2.5) * 0.005;
                        self.state.yaw += dx * sens;
                        self.state.pitch = std.math.clamp(self.state.pitch + dy * sens, -1.45, 1.45);
                    }
                    self.state.last_pointer = pos;
                    n.ui.needs_frame = true;
                    return true;
                }
            },
            .release => {
                if (self.state.is_dragging) {
                    self.state.is_dragging = false;
                    self.state.drag_anchor = null;
                    self.state.last_pointer = null;
                    n.ui.needs_frame = true;
                    return true;
                }
            },
            .scroll => |sc| {
                // Ignore touch-pan scroll queries so touch dragging uses .press/.motion/.release
                // instead of cancelling the press!
                if (sc.touch) return false;
                if (sc.dy < 0) {
                    self.state.zoomIn();
                } else if (sc.dy > 0) {
                    self.state.zoomOut();
                }
                n.ui.needs_frame = true;
                return true;
            },
            // Two fingers apart or together: zoomed in or out (it stops
            // turning: the first finger's press was taken back).
            .pinch => |p| {
                self.state.drag_vel_x = 0;
                self.state.drag_vel_y = 0;
                self.state.pinch(p.scale);
                n.ui.needs_frame = true;
                return true;
            },
            else => {},
        }
        return false;
    }
};

const testing = std.testing;

test "Globe view fits from smallest window to biggest without overflowing" {
    const font_data = kete.font;
    const f = try font_data.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();

    for ([_][2]u32{
        min_size,
        open_size,
        .{ 1280, 720 },
        .{ 1920, 1080 },
    }) |size| {
        u.frame(size[0], size[1], 0, Globe{
            .globe_gpu = null,
        });
        const Check = struct {
            fn none(n: *kete.WidgetNode) !void {
                try testing.expect(!n.overflow.any());
                for (n.children.items) |ch| try none(ch);
            }
        };
        try Check.none(u.root.?);
    }
}

test "dragging the globe with the mouse moves it immediately while dragging" {
    const font_data = kete.font;
    const f = try font_data.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();

    var state = Globe.State{};
    const init_yaw = state.yaw;
    const init_pitch = state.pitch;

    const Root = struct {
        s: *Globe.State,
        pub fn build(self: *const @This(), cx: *kete.BuildContext) kete.Widget {
            return (Globe{}).build(cx, self.s);
        }
    };

    u.frame(800, 600, 0, Root{ .s = &state });

    const Find = struct {
        fn globeNode(n: *kete.WidgetNode) ?*kete.WidgetNode {
            if (n.widget.is(GlobeView)) return n;
            for (n.children.items) |ch| if (globeNode(ch)) |found| return found;
            return null;
        }
    };
    const gn = Find.globeNode(u.root.?).?;
    const gpos = gn.position();
    const fovy: f32 = 45.0 * (std.math.pi / 180.0);
    const clicked_coord = globe.raycastSphere(400 - gpos[0], 300 - gpos[1], gn.size.w, gn.size.h, fovy, state.distance, state.yaw, state.pitch).?;

    // Press mouse button in the center of the globe:
    u.pointerButton(.{ 400, 300 }, .left, true);
    try testing.expect(state.is_dragging);
    try testing.expect(state.drag_anchor != null);

    // Move mouse while holding button down (before releasing):
    u.needs_frame = false;
    u.pointerMotion(.{ 480, 340 });

    // Globe yaw and pitch must have updated immediately during drag, and the clicked
    // point on the globe must now be directly under the new cursor position (480, 340):
    try testing.expect(state.yaw != init_yaw);
    try testing.expect(state.pitch != init_pitch);
    try testing.expect(u.needs_frame);
    const dragged_coord = globe.raycastSphere(480 - gpos[0], 340 - gpos[1], gn.size.w, gn.size.h, fovy, state.distance, state.yaw, state.pitch).?;
    try testing.expectApproxEqAbs(clicked_coord.lat, dragged_coord.lat, 0.05);
    try testing.expectApproxEqAbs(clicked_coord.lon, dragged_coord.lon, 0.05);

    // Release mouse button:
    u.pointerButton(.{ 480, 340 }, .left, false);
    try testing.expect(!state.is_dragging);
}

test "dragging the globe with touch moves it immediately without cancelling press" {
    const font_data = kete.font;
    const f = try font_data.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();

    var state = Globe.State{};
    const init_yaw = state.yaw;

    const Root = struct {
        s: *Globe.State,
        pub fn build(self: *const @This(), cx: *kete.BuildContext) kete.Widget {
            return (Globe{}).build(cx, self.s);
        }
    };

    u.frame(800, 600, 0, Root{ .s = &state });

    u.touchDown(1, .{ 400, 300 });
    try testing.expect(state.is_dragging);

    u.needs_frame = false;
    u.touchMotion(1, .{ 460, 320 });
    try testing.expect(state.is_dragging);
    try testing.expect(state.yaw != init_yaw);
    try testing.expect(u.needs_frame);

    u.touchUp(1);
    try testing.expect(!state.is_dragging);
}

test "two fingers pinch the globe bigger or smaller" {
    const font_data = kete.font;
    const f = try font_data.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var state = Globe.State{};
    const Root = struct {
        s: *Globe.State,
        pub fn build(self: *const @This(), cx: *kete.BuildContext) kete.Widget {
            return (Globe{}).build(cx, self.s);
        }
    };
    u.frame(800, 600, 0, Root{ .s = &state });
    const start = state.distance;
    // Apart, to half as far again: two thirds as far away.
    u.touchDown(1, .{ 350, 300 });
    u.touchDown(2, .{ 450, 300 });
    u.touchMotion(1, .{ 325, 300 });
    u.touchMotion(2, .{ 475, 300 });
    try testing.expectApproxEqAbs(start / 1.5, state.distance, 0.01);
    try testing.expect(!state.is_dragging);
    // Together, a long way: no further out than the wheel goes.
    u.touchMotion(1, .{ 395, 300 });
    u.touchMotion(2, .{ 405, 300 });
    try testing.expectEqual(@as(f32, 4.8), state.distance);
    u.touchUp(2);
    u.touchUp(1);
}

test "zooming in transitions to the 50m resolution dataset and renders cleanly" {
    const font_data = kete.font;
    const f = try font_data.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();

    var state = Globe.State{};
    try testing.expect(state.distance > detail_distance);

    const Root = struct {
        s: *Globe.State,
        pub fn build(self: *const @This(), cx: *kete.BuildContext) kete.Widget {
            return (Globe{}).build(cx, self.s);
        }
    };

    state.zoomIn();
    state.zoomIn();
    try testing.expect(state.distance <= detail_distance);

    u.frame(800, 600, 0, Root{ .s = &state });

    const Check = struct {
        fn none(n: *kete.WidgetNode) !void {
            try testing.expect(!n.overflow.any());
            for (n.children.items) |ch| try none(ch);
        }
    };
    try Check.none(u.root.?);
}

