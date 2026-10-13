//! The Maps window, as widgets: a clean, interactive 3D political globe
//! rendered with Natural Earth vectors, MapLibre globe colors, country
//! boundaries, coastlines, and labels, with a top-right fullscreen toggle.

const std = @import("std");
const app = @import("app");
const ui = @import("ui");
const gfx = @import("gfx");
const font = @import("font");
const vc4 = @import("vc4");
const map_data = @import("map_data");
const globe = @import("globe.zig");

pub const min_size = [2]u32{ 640, 420 };
pub const open_size = [2]u32{ 1024, 680 };

pub const button_bg = gfx.Color.argb(0xd8182232);
pub const label_color = gfx.Color.argb(0xff202834);
pub const label_halo_color = gfx.Color.argb(0xd8ffffff);

pub const Maps = struct {
    globe_gpu: ?*globe.GlobeGpu = null,
    on_close: ?ui.Callback = null,
    on_maximize: ?ui.Callback = null,
    on_fullscreen: ?ui.Callback = null,
    on_drag: ?ui.Callback = null,
    maximized: bool = true,
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
    };

    pub fn build(self: *const Maps, cx: *ui.Context, state: *State) ui.Widget {
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

        const is_fullscreen = self.fullscreen or cx.ui.fullscreen;
        const on_fullscreen = self.on_fullscreen orelse
            if (cx.ui.controls) |c| ui.Callback.of(c, app.Controls.toggleFullscreen) else null;

        const a = cx.ui.arena();
        var layers: std.ArrayList(ui.Widget) = .empty;

        // 1. 3D Political Vector Globe (fills background, clipped to bounds)
        layers.append(a, cx.make(GlobeView{
            .maps = self,
            .state = state,
        })) catch {};

        // 2. Top-Right Fullscreen Toggle Button
        layers.append(a, cx.make(ui.Align{
            .alignment = .top_right,
            .child = cx.make(ui.Padding{
                .padding = .{ .top = 12, .right = 12 },
                .child = cx.make(ui.Decorated{
                    .color = button_bg,
                    .radius = gfx.Radii.all(20),
                    .child = cx.make(ui.IconButton{
                        .icon = if (is_fullscreen) .fullscreen_exit else .fullscreen,
                        .on_press = on_fullscreen,
                    }),
                }),
            }),
        })) catch {};

        const content = cx.make(ui.Overlay{ .children = layers.items });

        if (is_fullscreen) {
            return content;
        }

        return cx.make(ui.Column{
            .cross_axis_alignment = .stretch,
            .children = &.{
                cx.make(ui.TitleBar{
                    .title = "Maps",
                    .on_close = self.on_close,
                    .on_maximize = self.on_maximize,
                    .on_drag = self.on_drag,
                    .maximized = self.maximized,
                }),
                cx.make(ui.Expanded{ .child = content }),
            },
        });
    }
};

/// Widget rendering the 3D Vector Globe and its coastline, boundary, and label overlays.
pub const GlobeView = struct {
    pub const clips_children = true;

    maps: *const Maps,
    state: *Maps.State,

    pub fn layout(self: *const GlobeView, _: *ui.Node, c: ui.Constraints) ui.Size {
        _ = self;
        return c.biggest();
    }

    pub fn paint(self: *const GlobeView, n: *ui.Node, p: *ui.Painter) void {
        const w = n.size.w;
        const h = n.size.h;
        if (w <= 1 or h <= 1) return;

        // 1. Background canvas (rendered BEFORE the 3D GPU globe):
        const bg_c = p.canvas();
        bg_c.fillRect(.{ .x = 0, .y = 0, .w = w, .h = h }, gfx.Color.rgb(0x0b101b));

        const fovy = 45.0 * (std.math.pi / 180.0);
        const tan_fov = @tan(fovy * 0.5);
        const sphere_screen_r = (h * 0.5) / (tan_fov * self.state.distance);
        const center_x = w * 0.5;
        const center_y = h * 0.5;

        if (sphere_screen_r > 5) {
            bg_c.fillCircle(.{ center_x, center_y }, sphere_screen_r * 1.035, gfx.Color.argb(0x1868b8f8));
            bg_c.fillCircle(.{ center_x, center_y }, sphere_screen_r * 1.015, gfx.Color.argb(0x2890d4ff));
        }

        // 2. 3D GPU Vector Globe (Ocean sphere + Natural Earth country polygons):
        if (self.maps.globe_gpu) |_| {
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
        self.paintOverlays(w, h, fg_c, p);
    }

    fn drawGlobe(self: *const GlobeView, frame: *vc4.render.Frame, area: ui.GpuArea) anyerror!void {
        const vp = area.viewport;
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

        try self.maps.globe_gpu.?.draw(
            frame,
            area.viewport,
            area.scissor,
            mvp,
            rot,
            sun_dir,
            cam_model,
        );
    }

    fn paintOverlays(self: *const GlobeView, w: f32, h: f32, c: *gfx.Canvas, p: *ui.Painter) void {
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

        // 1. In CPU-only preview mode (no GPU), draw 2D projected country polygons
        // so unit tests and CPU previews show the political map as well:
        if (self.maps.globe_gpu == null) {
            var ii: usize = 0;
            while (ii + 2 < map_data.country_indices.len) : (ii += 3) {
                const v0 = map_data.country_vertices[map_data.country_indices[ii]];
                const v1 = map_data.country_vertices[map_data.country_indices[ii + 1]];
                const v2 = map_data.country_vertices[map_data.country_indices[ii + 2]];

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

        // 2. Coastlines (#198EC8 from MapLibre globe style):
        const coast_col = gfx.Color.argb(map_data.coastline_color);
        drawProjectedSpans(c, &map_data.coastline_points, &map_data.coastline_spans, mvp, cam_model, w, h, 1.2, coast_col);

        // 3. International Country Boundaries (#FFFFFF from MapLibre globe style):
        const border_col = gfx.Color.argb(map_data.boundary_color);
        drawProjectedSpans(c, &map_data.border_points, &map_data.border_spans, mvp, cam_model, w, h, 1.3, border_col);

        // 4. Country Name Labels (decluttered by zoom level and screen-space bounding boxes):
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

        for (map_data.country_labels) |lbl| {
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

    pub fn event(self: *const GlobeView, n: *ui.Node, e: ui.Event) bool {
        switch (e) {
            .press => |pr| {
                if (pr.button == ui.btn_left) {
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
            else => {},
        }
        return false;
    }
};

const testing = std.testing;

test "Maps view fits from smallest window to biggest without overflowing" {
    const font_data = @import("font");
    const f = try font_data.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();

    for ([_][2]u32{
        min_size,
        open_size,
        .{ 1280, 720 },
        .{ 1920, 1080 },
    }) |size| {
        u.frame(size[0], size[1], 0, Maps{
            .globe_gpu = null,
        });
        const Check = struct {
            fn none(n: *ui.Node) !void {
                try testing.expect(!n.overflow.any());
                for (n.children.items) |ch| try none(ch);
            }
        };
        try Check.none(u.root.?);
    }
}

test "dragging the globe with the mouse moves it immediately while dragging" {
    const font_data = @import("font");
    const f = try font_data.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();

    var state = Maps.State{};
    const init_yaw = state.yaw;
    const init_pitch = state.pitch;

    const Root = struct {
        s: *Maps.State,
        pub fn build(self: *const @This(), cx: *ui.Context) ui.Widget {
            return (Maps{}).build(cx, self.s);
        }
    };

    u.frame(800, 600, 0, Root{ .s = &state });

    const Find = struct {
        fn globeNode(n: *ui.Node) ?*ui.Node {
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
    u.pointerButton(.{ 400, 300 }, ui.btn_left, true);
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
    u.pointerButton(.{ 480, 340 }, ui.btn_left, false);
    try testing.expect(!state.is_dragging);
}

test "dragging the globe with touch moves it immediately without cancelling press" {
    const font_data = @import("font");
    const f = try font_data.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();

    var state = Maps.State{};
    const init_yaw = state.yaw;

    const Root = struct {
        s: *Maps.State,
        pub fn build(self: *const @This(), cx: *ui.Context) ui.Widget {
            return (Maps{}).build(cx, self.s);
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
