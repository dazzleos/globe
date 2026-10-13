//! The Maps window, as widgets: the 3D interactive globe filling the window,
//! with vector geographic overlays (coastlines, country borders, graticule,
//! cities/capitals), an educational inspector card, continent quick-jump chips,
//! and layers control panel.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const vc4 = @import("vc4");
const locale = @import("locale");
const map_data = @import("map_data.zig");
const globe = @import("globe.zig");
const tiles = @import("tiles.zig");

pub const min_size = [2]u32{ 640, 420 };
pub const open_size = [2]u32{ 1024, 680 };

pub const text_color = gfx.Color.argb(0xfff0f4fa);
pub const dim_color = gfx.Color.argb(0xff9ab0cc);
pub const accent_color = gfx.Color.argb(0xff4ca0e8);
pub const gold_color = gfx.Color.argb(0xffe8a838);
pub const card_bg = gfx.Color.argb(0xec142236);
pub const chip_bg = gfx.Color.argb(0xd0182840);

pub const Maps = struct {
    globe_gpu: ?*globe.GlobeGpu = null,
    tile_manager: *tiles.TileManager,
    on_close: ?ui.Callback = null,
    on_maximize: ?ui.Callback = null,
    on_drag: ?ui.Callback = null,
    maximized: bool = true,
    width: f32 = 1280,

    pub const State = struct {
        yaw: f32 = 0.2, // ~11° East (Europe/Africa centered initially)
        pitch: f32 = 0.25, // ~14° North
        distance: f32 = 2.5, // Space orbit view

        target_yaw: ?f32 = null,
        target_pitch: ?f32 = null,
        target_distance: ?f32 = null,

        drag_vel_x: f32 = 0,
        drag_vel_y: f32 = 0,
        is_dragging: bool = false,
        last_pointer: ?[2]f32 = null,
        last_frame_ns: ?u64 = null,

        auto_rotate: bool = false,
        day_night_lighting: bool = true,
        atmosphere_glow: bool = true,
        show_graticule: bool = true,
        show_borders: bool = true,
        show_cities: bool = true,
        show_layers_panel: bool = false,

        selected_city: ?map_data.City = null,
        hover_city: ?map_data.City = null,

        pub fn zoomIn(s: *State) void {
            s.distance = @max(s.distance * 0.82, 1.25);
            s.target_distance = null;
        }

        pub fn zoomOut(s: *State) void {
            s.distance = @min(s.distance * 1.20, 5.0);
            s.target_distance = null;
        }

        pub fn resetView(s: *State) void {
            s.target_yaw = 0.2;
            s.target_pitch = 0.25;
            s.target_distance = 2.5;
            s.selected_city = null;
        }

        pub fn toggleAutoRotate(s: *State) void {
            s.auto_rotate = !s.auto_rotate;
        }

        pub fn toggleDayNight(s: *State, on: bool) void {
            s.day_night_lighting = on;
        }

        pub fn toggleAtmosphere(s: *State, on: bool) void {
            s.atmosphere_glow = on;
        }

        pub fn toggleGraticule(s: *State, on: bool) void {
            s.show_graticule = on;
        }

        pub fn toggleBorders(s: *State, on: bool) void {
            s.show_borders = on;
        }

        pub fn toggleCities(s: *State, on: bool) void {
            s.show_cities = on;
        }

        pub fn toggleLayers(s: *State) void {
            s.show_layers_panel = !s.show_layers_panel;
        }

        pub fn closeDetailCard(s: *State) void {
            s.selected_city = null;
        }

        pub fn flyToCity(s: *State, c: map_data.City) void {
            s.selected_city = c;
            // Target yaw and pitch to center on this city:
            // City lon in degrees to yaw in radians:
            const lon_rad = c.lon * (std.math.pi / 180.0);
            const lat_rad = c.lat * (std.math.pi / 180.0);
            s.target_yaw = -lon_rad;
            s.target_pitch = lat_rad;
            s.target_distance = 1.6; // Zoom closer to city
        }

        pub fn flyToContinent(s: *State, cont: map_data.Continent) void {
            s.selected_city = null;
            const lon_rad = cont.center.lon * (std.math.pi / 180.0);
            const lat_rad = cont.center.lat * (std.math.pi / 180.0);
            s.target_yaw = -lon_rad;
            s.target_pitch = lat_rad;
            s.target_distance = cont.zoom_distance;
        }
    };

    pub fn build(self: *const Maps, cx: *ui.Context, state: *State) ui.Widget {
        const now = cx.now();
        const dt = if (state.last_frame_ns) |last|
            @as(f32, @floatFromInt(now -| last)) / @as(f32, @floatFromInt(std.time.ns_per_s))
        else
            0.016;
        state.last_frame_ns = now;

        // Smooth camera interpolation towards target if flying:
        var animating = false;
        if (state.target_yaw) |ty| {
            animating = true;
            // Shortest angle difference:
            var diff = ty - state.yaw;
            while (diff > std.math.pi) diff -= 2.0 * std.math.pi;
            while (diff < -std.math.pi) diff += 2.0 * std.math.pi;
            if (@abs(diff) < 0.005) {
                state.yaw = ty;
                state.target_yaw = null;
            } else {
                state.yaw += diff * @min(dt * 6.0, 1.0);
            }
        }
        if (state.target_pitch) |tp| {
            animating = true;
            const diff = tp - state.pitch;
            if (@abs(diff) < 0.005) {
                state.pitch = tp;
                state.target_pitch = null;
            } else {
                state.pitch += diff * @min(dt * 6.0, 1.0);
            }
        }
        if (state.target_distance) |td| {
            animating = true;
            const diff = td - state.distance;
            if (@abs(diff) < 0.01) {
                state.distance = td;
                state.target_distance = null;
            } else {
                state.distance += diff * @min(dt * 6.0, 1.0);
            }
        }

        // Inertia when not dragging:
        if (!state.is_dragging and !animating) {
            if (@abs(state.drag_vel_x) > 0.001 or @abs(state.drag_vel_y) > 0.001) {
                state.yaw += state.drag_vel_x * dt;
                state.pitch = std.math.clamp(state.pitch + state.drag_vel_y * dt, -1.45, 1.45);
                state.drag_vel_x *= @exp(-dt * 4.0); // Friction decay
                state.drag_vel_y *= @exp(-dt * 4.0);
                cx.requestFrame();
            } else if (state.auto_rotate) {
                state.yaw += dt * 0.12; // Serene auto-rotation
                cx.requestFrame();
            }
        }

        if (animating) cx.requestFrame();

        const a = cx.ui.arena();
        var layers: std.ArrayList(ui.Widget) = .empty;

        // 1. Globe 3D view (fills background)
        layers.append(a, cx.make(GlobeView{
            .maps = self,
            .state = state,
        })) catch {};

        // 2. Top Bar: Continent Chips & Quick Jump
        layers.append(a, cx.make(ui.Align{
            .alignment = .top_left,
            .child = cx.make(ui.Padding{
                .padding = .{ .left = 16, .top = 12, .right = 16 },
                .child = self.topBar(cx, state),
            }),
        })) catch {};

        // 3. Floating Action Buttons (Right Side)
        layers.append(a, cx.make(ui.Align{
            .alignment = .center_right,
            .child = cx.make(ui.Padding{
                .padding = .{ .right = 16 },
                .child = self.floatingControls(cx, state),
            }),
        })) catch {};

        // 4. Bottom HUD: Coordinates & Information
        layers.append(a, cx.make(ui.Align{
            .alignment = .bottom_left,
            .child = cx.make(ui.Padding{
                .padding = .{ .left = 16, .bottom = 12, .right = 16 },
                .child = self.bottomHud(cx, state),
            }),
        })) catch {};

        // 5. Educational Detail Card (if city selected)
        if (state.selected_city) |city| {
            layers.append(a, cx.make(ui.Align{
                .alignment = .top_right,
                .child = cx.make(ui.Padding{
                    .padding = .{ .right = 16, .top = 56 },
                    .child = self.educationalCard(cx, state, city),
                }),
            })) catch {};
        }

        // 6. Layers Settings Drawer (if toggled)
        if (state.show_layers_panel) {
            layers.append(a, cx.make(ui.Align{
                .alignment = .top_left,
                .child = cx.make(ui.Padding{
                    .padding = .{ .left = 16, .top = 56 },
                    .child = self.layersPanel(cx, state),
                }),
            })) catch {};
        }

        const content = cx.make(ui.Overlay{ .children = layers.items });

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

    fn topBar(self: *const Maps, cx: *ui.Context, state: *State) ui.Widget {
        var chips: std.ArrayList(ui.Widget) = .empty;
        const a = cx.ui.arena();

        chips.append(a, cx.make(ui.OutlinedButton{
            .label = "Layers",
            .icon = .layers,
            .on_press = .of(state, State.toggleLayers),
        })) catch {};

        // Choose how many continents to display based on window width so they never overflow
        const cont_count: usize = if (self.width >= 1150)
            map_data.continents.len
        else if (self.width >= 950)
            6
        else if (self.width >= 720)
            5
        else
            4;

        for (map_data.continents[0..@min(cont_count, map_data.continents.len)]) |cont| {
            const Jump = struct {
                s: *State,
                c: map_data.Continent,
                fn call(j: *@This()) void {
                    j.s.flyToContinent(j.c);
                }
            };
            const j_ptr = a.create(Jump) catch continue;
            j_ptr.* = .{ .s = state, .c = cont };
            chips.append(a, cx.make(ui.Chip{
                .label = cont.name,
                .on_press = .of(j_ptr, Jump.call),
            })) catch {};
        }

        return cx.make(ui.Row{
            .main_axis_size = .min,
            .spacing = 8,
            .children = chips.items,
        });
    }

    fn floatingControls(self: *const Maps, cx: *ui.Context, state: *State) ui.Widget {
        _ = self;
        return cx.make(ui.Decorated{
            .color = card_bg,
            .radius = gfx.Radii.all(12),
            .child = cx.make(ui.Padding{
                .padding = .all(8),
                .child = cx.make(ui.Column{
                    .main_axis_size = .min,
                    .spacing = 8,
                    .children = &.{
                        cx.make(ui.OutlinedButton{
                            .label = "+",
                            .icon = .zoom_in,
                            .on_press = .of(state, State.zoomIn),
                        }),
                        cx.make(ui.OutlinedButton{
                            .label = "-",
                            .icon = .zoom_out,
                            .on_press = .of(state, State.zoomOut),
                        }),
                        cx.make(ui.OutlinedButton{
                            .label = if (state.auto_rotate) "Pause" else "Spin",
                            .icon = if (state.auto_rotate) .pause else .play_arrow,
                            .on_press = .of(state, State.toggleAutoRotate),
                        }),
                        cx.make(ui.OutlinedButton{
                            .label = "Reset",
                            .icon = .my_location,
                            .on_press = .of(state, State.resetView),
                        }),
                    },
                }),
            }),
        });
    }

    fn bottomHud(self: *const Maps, cx: *ui.Context, state: *State) ui.Widget {
        // Calculate center coordinate from camera rotation:
        const center_lat = state.pitch * (180.0 / std.math.pi);
        const center_lon = -state.yaw * (180.0 / std.math.pi);
        const alt_km = @as(u32, @intFromFloat(@max(state.distance - 1.0, 0.1) * 6371.0));

        var status_buf: [64]u8 = undefined;
        const net_status = self.tile_manager.statusText(&status_buf);

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

        const info = cx.fmt("{s}, {s}  ·  Altitude: {d} km  ·  {s}", .{
            lat_str,
            lon_str,
            alt_km,
            net_status,
        });

        return cx.make(ui.Decorated{
            .color = card_bg,
            .radius = gfx.Radii.all(10),
            .child = cx.make(ui.Padding{
                .padding = .{ .left = 14, .right = 14, .top = 8, .bottom = 8 },
                .child = cx.make(ui.Text{
                    .text = info,
                    .style = .{ .size = 14, .color = text_color },
                    .wrap = false,
                }),
            }),
        });
    }

    fn educationalCard(self: *const Maps, cx: *ui.Context, state: *State, city: map_data.City) ui.Widget {
        _ = self;
        const Fly = struct {
            s: *State,
            c: map_data.City,
            fn call(f: *@This()) void {
                f.s.flyToCity(f.c);
            }
        };
        const fly_ptr = cx.ui.arena().create(Fly) catch return cx.make(ui.Empty{});
        fly_ptr.* = .{ .s = state, .c = city };

        const coord_str = cx.fmt("{d:.2}° {s}, {d:.2}° {s}", .{
            @abs(city.lat),
            if (city.lat >= 0) "N" else "S",
            @abs(city.lon),
            if (city.lon >= 0) "E" else "W",
        });

        return cx.make(ui.Decorated{
            .color = card_bg,
            .radius = gfx.Radii.all(14),
            .child = cx.make(ui.ConstrainedBox{
                .constraints = .{ .min_w = 320, .max_w = 380 },
                .child = cx.make(ui.Padding{
                    .padding = .all(18),
                    .child = cx.make(ui.Column{
                        .main_axis_size = .min,
                        .cross_axis_alignment = .start,
                        .spacing = 8,
                        .children = &.{
                            cx.make(ui.Row{
                                .cross_axis_alignment = .center,
                                .children = &.{
                                    cx.make(ui.Expanded{
                                        .child = cx.make(ui.Text{
                                            .text = city.name,
                                            .style = .{ .size = 22, .color = text_color },
                                            .wrap = false,
                                        }),
                                    }),
                                    cx.make(ui.IconButton{
                                        .icon = .close,
                                        .on_press = .of(state, State.closeDetailCard),
                                    }),
                                },
                            }),
                            cx.make(ui.Text{
                                .text = cx.fmt("{s}  ·  {s}", .{ city.country, city.continent }),
                                .style = .{ .size = 15, .color = accent_color },
                                .wrap = false,
                            }),
                            cx.make(ui.SizedBox{ .height = 4 }),
                            cx.make(ui.Text{
                                .text = cx.fmt("Coordinates: {s}", .{coord_str}),
                                .style = .{ .size = 13, .color = dim_color },
                                .wrap = false,
                            }),
                            cx.make(ui.Text{
                                .text = cx.fmt("Population: {s}", .{city.population}),
                                .style = .{ .size = 13, .color = dim_color },
                                .wrap = false,
                            }),
                            cx.make(ui.SizedBox{ .height = 6 }),
                            cx.make(ui.Text{
                                .text = city.fact,
                                .style = .{ .size = 14, .color = text_color },
                                .wrap = true,
                            }),
                            cx.make(ui.SizedBox{ .height = 10 }),
                            cx.make(ui.Row{
                                .spacing = 8,
                                .main_axis_size = .min,
                                .children = &.{
                                    cx.make(ui.OutlinedButton{
                                        .label = "Fly Closer",
                                        .icon = .my_location,
                                        .on_press = .of(fly_ptr, Fly.call),
                                    }),
                                },
                            }),
                        },
                    }),
                }),
            }),
        });
    }

    fn layersPanel(self: *const Maps, cx: *ui.Context, state: *State) ui.Widget {
        const ToggleTiles = struct {
            m: *tiles.TileManager,
            fn call(t: *@This(), on: bool) void {
                t.m.enabled = on;
            }
        };
        const tile_toggle = cx.ui.arena().create(ToggleTiles) catch return cx.make(ui.Empty{});
        tile_toggle.* = .{ .m = self.tile_manager };

        return cx.make(ui.Decorated{
            .color = card_bg,
            .radius = gfx.Radii.all(14),
            .child = cx.make(ui.ConstrainedBox{
                .constraints = .{ .min_w = 280, .max_w = 340 },
                .child = cx.make(ui.Padding{
                    .padding = .all(18),
                    .child = cx.make(ui.Column{
                        .main_axis_size = .min,
                        .cross_axis_alignment = .start,
                        .spacing = 10,
                        .children = &.{
                            cx.make(ui.Row{
                                .children = &.{
                                    cx.make(ui.Expanded{
                                        .child = cx.make(ui.Text{
                                            .text = "Map Layers",
                                            .style = .{ .size = 18, .color = text_color },
                                            .wrap = false,
                                        }),
                                    }),
                                    cx.make(ui.IconButton{
                                        .icon = .close,
                                        .on_press = .of(state, State.toggleLayers),
                                    }),
                                },
                            }),
                            cx.make(ui.Switch{
                                .value = state.day_night_lighting,
                                .on_changed = .of(state, State.toggleDayNight),
                                .label = "Day & Night Lighting",
                            }),
                            cx.make(ui.Switch{
                                .value = state.atmosphere_glow,
                                .on_changed = .of(state, State.toggleAtmosphere),
                                .label = "Atmosphere Glow",
                            }),
                            cx.make(ui.Switch{
                                .value = state.show_graticule,
                                .on_changed = .of(state, State.toggleGraticule),
                                .label = "Lat/Lon Graticule Grid",
                            }),
                            cx.make(ui.Switch{
                                .value = state.show_borders,
                                .on_changed = .of(state, State.toggleBorders),
                                .label = "Coastlines & Borders",
                            }),
                            cx.make(ui.Switch{
                                .value = state.show_cities,
                                .on_changed = .of(state, State.toggleCities),
                                .label = "Capitals & Cities",
                            }),
                            cx.make(ui.Switch{
                                .value = self.tile_manager.enabled,
                                .on_changed = .of(tile_toggle, ToggleTiles.call),
                                .label = "Remote Tiles (OSM)",
                            }),
                        },
                    }),
                }),
            }),
        });
    }
};

/// Widget rendering the 3D Globe and its vector overlays.
pub const GlobeView = struct {
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

        // Space background with subtle stars:
        const c = p.canvas();
        c.fillRect(.{ .x = 0, .y = 0, .w = w, .h = h }, gfx.Color.rgb(0x060c18));

        // Atmospheric outer glow halo:
        if (self.state.atmosphere_glow) {
            const fovy = 45.0 * (std.math.pi / 180.0);
            const tan_fov = @tan(fovy * 0.5);
            // Screen radius of globe sphere:
            const sphere_screen_r = (h * 0.5) / (tan_fov * self.state.distance);
            const center_x = w * 0.5;
            const center_y = h * 0.5;

            if (sphere_screen_r > 5) {
                // Outer cyan halo rings fading out:
                c.fillCircle(.{ center_x, center_y }, sphere_screen_r * 1.055, gfx.Color.argb(0x183ca0e8));
                c.fillCircle(.{ center_x, center_y }, sphere_screen_r * 1.030, gfx.Color.argb(0x284cb5f0));
            }
        }

        // 3D GPU Globe draw:
        if (self.maps.globe_gpu) |_| {
            var key = std.hash.Wyhash.init(0);
            key.update(std.mem.asBytes(&self.state.yaw));
            key.update(std.mem.asBytes(&self.state.pitch));
            key.update(std.mem.asBytes(&self.state.distance));
            key.update(std.mem.asBytes(&self.state.day_night_lighting));
            key.update(std.mem.asBytes(&self.state.atmosphere_glow));

            p.gpuWith(.{ .key = key.final() }, self, drawGlobe);
        } else {
            // Software preview circle for host tests without GPU:
            const center_x = w * 0.5;
            const center_y = h * 0.5;
            const r = @min(w, h) * 0.38;
            c.fillCircle(.{ center_x, center_y }, r, gfx.Color.rgb(0x1a3856));
        }

        // Vector Overlays on Canvas (drawn in a new canvas segment on top of the 3D globe):
        self.paintOverlays(w, h, p.canvas());
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

        // Sun direction (towards sun in view/world space):
        const sun_dir = [3]f32{ -0.6, 0.4, 0.7 };

        // Camera position in model space (eye is [0, 0, distance] in view space, inverse-rotated by rot):
        const cos_p = @cos(-self.state.pitch);
        const sin_p = @sin(-self.state.pitch);
        const d = self.state.distance;
        const eye_pitch = [3]f32{ 0, -d * sin_p, d * cos_p };
        const cos_y = @cos(-self.state.yaw);
        const sin_y = @sin(-self.state.yaw);
        const cam_pos = [3]f32{
            eye_pitch[0] * cos_y + eye_pitch[2] * sin_y,
            eye_pitch[1],
            -eye_pitch[0] * sin_y + eye_pitch[2] * cos_y,
        };

        try self.maps.globe_gpu.?.draw(
            frame,
            area.viewport,
            area.scissor,
            mvp,
            rot,
            sun_dir,
            self.state.day_night_lighting,
            cam_pos,
            self.state.atmosphere_glow,
        );
    }

    fn paintOverlays(self: *const GlobeView, w: f32, h: f32, c: *gfx.Canvas) void {
        const aspect = w / h;
        const proj = globe.perspective(45.0 * (std.math.pi / 180.0), aspect, 0.1, 20.0);
        const view_trans = globe.translation(0, 0, -self.state.distance);
        const rot_x = globe.rotationX(self.state.pitch);
        const rot_y = globe.rotationY(self.state.yaw);
        const rot = globe.mul(rot_x, rot_y);
        const view = globe.mul(view_trans, rot);
        const mvp = globe.mul(proj, view);

        // Camera position in model space:
        // Eye is [0, 0, distance] in world space; inverse-rotate by rot:
        // inv(rot) = inv(rot_y) * inv(rot_x)
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

        // 1. Graticule Lines (Equator, Prime Meridian, Tropics):
        if (self.state.show_graticule) {
            for (map_data.graticules) |gr| {
                const color = switch (gr.kind) {
                    .equator => gfx.Color.argb(0xa0e0a838),
                    .prime_meridian => gfx.Color.argb(0x904ca8d8),
                    .tropic => gfx.Color.argb(0x507090b8),
                    .polar => gfx.Color.argb(0x5090b0d8),
                    .grid => gfx.Color.argb(0x306080a0),
                };

                var pts: [65]gfx.Point = undefined;
                var count: usize = 0;

                if (gr.lat) |lat| {
                    // Parallel ring:
                    var i: u32 = 0;
                    while (i <= 64) : (i += 1) {
                        const lon = @as(f32, @floatFromInt(i)) / 64.0 * 360.0 - 180.0;
                        const p3 = globe.latLonToCartesian(lat, lon, 1.001);
                        if (globe.project(p3, mvp, cam_model, w, h)) |scr| {
                            pts[count] = .{ scr[0], scr[1] };
                            count += 1;
                        } else {
                            if (count >= 2) {
                                c.strokePolyline(pts[0..count], false, 1.2, color);
                            }
                            count = 0;
                        }
                    }
                    if (count >= 2) {
                        c.strokePolyline(pts[0..count], false, 1.2, color);
                    }
                } else if (gr.lon) |lon| {
                    // Meridian line:
                    var i: u32 = 0;
                    while (i <= 64) : (i += 1) {
                        const lat = @as(f32, @floatFromInt(i)) / 64.0 * 180.0 - 90.0;
                        const p3 = globe.latLonToCartesian(lat, lon, 1.001);
                        if (globe.project(p3, mvp, cam_model, w, h)) |scr| {
                            pts[count] = .{ scr[0], scr[1] };
                            count += 1;
                        } else {
                            if (count >= 2) {
                                c.strokePolyline(pts[0..count], false, 1.2, color);
                            }
                            count = 0;
                        }
                    }
                    if (count >= 2) {
                        c.strokePolyline(pts[0..count], false, 1.2, color);
                    }
                }
            }
        }

        // 2. Coastlines & Continent Outlines:
        if (self.state.show_borders) {
            const border_color = gfx.Color.argb(0xb0a8d4a0);
            for (map_data.landmasses) |lm| {
                var pts: [64]gfx.Point = undefined;
                var count: usize = 0;

                for (lm.points) |p| {
                    const p3 = globe.latLonToCartesian(p[1], p[0], 1.002);
                    if (globe.project(p3, mvp, cam_model, w, h)) |scr| {
                        if (count < pts.len) {
                            pts[count] = .{ scr[0], scr[1] };
                            count += 1;
                        }
                    } else {
                        if (count >= 2) {
                            c.strokePolyline(pts[0..count], false, 1.5, border_color);
                        }
                        count = 0;
                    }
                }
                if (count >= 2) {
                    c.strokePolyline(pts[0..count], false, 1.5, border_color);
                }
            }
        }

        // 3. Capitals and Cities:
        if (self.state.show_cities) {
            for (map_data.cities) |city| {
                const p3 = globe.latLonToCartesian(city.lat, city.lon, 1.003);
                if (globe.project(p3, mvp, cam_model, w, h)) |scr| {
                    const is_sel = if (self.state.selected_city) |sc| std.mem.eql(u8, sc.name, city.name) else false;

                    if (is_sel) {
                        // Highlight ring
                        c.fillCircle(.{ scr[0], scr[1] }, 9.0, gfx.Color.argb(0x40e8a838));
                        c.strokeCircle(.{ scr[0], scr[1] }, 8.0, 1.5, gold_color);
                        c.fillCircle(.{ scr[0], scr[1] }, 4.5, gold_color);
                    } else if (city.is_capital) {
                        c.fillCircle(.{ scr[0], scr[1] }, 4.0, gfx.Color.argb(0xffffffff));
                        c.strokeCircle(.{ scr[0], scr[1] }, 4.0, 1.0, gfx.Color.argb(0xdd102030));
                    } else {
                        c.fillCircle(.{ scr[0], scr[1] }, 3.0, gfx.Color.argb(0xdd8ec4f4));
                    }
                }
            }
        }
    }

    pub fn event(self: *const GlobeView, n: *ui.Node, e: ui.Event) bool {
        const w = n.size.w;
        const h = n.size.h;

        switch (e) {
            .press => |pr| {
                if (pr.button == 0x110) { // Primary left click
                    self.state.is_dragging = true;
                    self.state.last_pointer = pr.pos;
                    self.state.drag_vel_x = 0;
                    self.state.drag_vel_y = 0;
                    self.state.target_yaw = null;
                    self.state.target_pitch = null;

                    // Raycast to check if a city was clicked:
                    const hit = globe.raycastSphere(
                        pr.pos[0],
                        pr.pos[1],
                        w,
                        h,
                        45.0 * (std.math.pi / 180.0),
                        self.state.distance,
                        self.state.yaw,
                        self.state.pitch,
                    );

                    if (hit) |coord| {
                        // Check if close to any city:
                        var closest_city: ?map_data.City = null;
                        var closest_dist: f32 = 8.0; // Max degree radius
                        for (map_data.cities) |city| {
                            const d_lat = city.lat - coord.lat;
                            const d_lon = (city.lon - coord.lon) * @cos(coord.lat * (std.math.pi / 180.0));
                            const dist = @sqrt(d_lat * d_lat + d_lon * d_lon);
                            if (dist < closest_dist) {
                                closest_dist = dist;
                                closest_city = city;
                            }
                        }
                        if (closest_city) |c| {
                            self.state.selected_city = c;
                        }
                    }
                    return true;
                }
            },
            .motion => |pos| {
                if (self.state.is_dragging) {
                    if (self.state.last_pointer) |last| {
                        const dx = pos[0] - last[0];
                        const dy = pos[1] - last[1];

                        // Sensitivity scaled by distance (zoomed in -> finer rotation):
                        const sens = (self.state.distance / 2.5) * 0.005;
                        const d_yaw = dx * sens;
                        const d_pitch = dy * sens;

                        self.state.yaw += d_yaw;
                        self.state.pitch = std.math.clamp(self.state.pitch + d_pitch, -1.45, 1.45);

                        // Velocity for momentum:
                        self.state.drag_vel_x = dx * sens * 30.0;
                        self.state.drag_vel_y = dy * sens * 30.0;
                    }
                    self.state.last_pointer = pos;
                    return true;
                }
            },
            .release => {
                self.state.is_dragging = false;
                self.state.last_pointer = null;
                return true;
            },
            .scroll => |sc| {
                if (sc.dy < 0) {
                    self.state.zoomIn();
                } else if (sc.dy > 0) {
                    self.state.zoomOut();
                }
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

    var tm = tiles.TileManager.init(testing.allocator);
    defer tm.deinit();

    for ([_][2]u32{
        min_size,
        open_size,
        .{ 1280, 720 },
        .{ 1920, 1080 },
    }) |size| {
        u.frame(size[0], size[1], 0, Maps{
            .globe_gpu = null,
            .tile_manager = &tm,
            .width = @floatFromInt(size[0]),
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

test "zoom in and zoom out state transitions" {
    var state = Maps.State{};
    const init_dist = state.distance;
    state.zoomIn();
    try testing.expect(state.distance < init_dist);
    state.zoomOut();
    try testing.expect(state.distance > 1.25);
}

test "flying to a city" {
    var state = Maps.State{};
    state.flyToCity(map_data.cities[0]); // London
    try testing.expect(state.selected_city != null);
    try testing.expectEqualStrings("London", state.selected_city.?.name);
    try testing.expect(state.target_yaw != null);
    try testing.expect(state.target_pitch != null);
}

test "layer toggles" {
    var state = Maps.State{};
    try testing.expect(state.day_night_lighting);
    state.toggleDayNight(false);
    try testing.expect(!state.day_night_lighting);
    state.toggleGraticule(false);
    try testing.expect(!state.show_graticule);
}
