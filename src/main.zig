//! Maps: an interactive 3D globe application for Dazzle, showing
//! the Earth with day/night illumination, atmospheric limb glow,
//! offline coastlines, countries, world capitals, and remote tile access.
//!
//!     dazzle-maps [font.ttf]
//!
//! Runs until its window is closed.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const locale = @import("locale");
const font = @import("font");
const vc4 = @import("vc4");
const app = @import("app");
const ui = @import("ui");
const wayland = @import("wayland");
const build_info = @import("build_info");

const map_data = @import("map_data.zig");
const globe = @import("globe.zig");
const tiles = @import("tiles.zig");
const view = @import("view.zig");

const print = sys.print;

const background = 0xff080e18;
var frame: vc4.render.Frame = undefined;

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.logToKmsgIfStderr();
    var args = init.args.iterate();
    _ = args.skip();
    var font_buf: [512]u8 = undefined;
    const font_path: [*:0]const u8 = args.next() orelse sys.fontFile(&font_buf, font.default_font_file);
    print("dazzle: maps (build {s}) running as uid {d}\n", .{ build_info.commit, linux.getuid() });

    run(init, font_path) catch |err| {
        print(sys.log_error ++ "dazzle-maps: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn loadFont(gpa: std.mem.Allocator, path: [*:0]const u8) ?font.Font {
    const data = sys.readFileAlloc(gpa, path, 32 * 1024 * 1024) catch |err| {
        print(sys.log_warning ++ "dazzle-maps: cannot read the font {s} ({s}); no text\n", .{ path, @errorName(err) });
        return null;
    };
    return font.Font.init(data) catch |err| {
        print("dazzle-maps: {s} is not a usable font ({s}); no text\n", .{ path, @errorName(err) });
        return null;
    };
}

fn openWindow(gpa: std.mem.Allocator, init: std.process.Init.Minimal, dev: *vc4.Device) !*app.Window {
    const Environ = std.process.Environ;
    var path_buf: [128]u8 = undefined;
    const path = wayland.client.socketPath(&path_buf, Environ.getPosix(init.environ, "XDG_RUNTIME_DIR"), Environ.getPosix(init.environ, "WAYLAND_DISPLAY")) catch {
        print("dazzle-maps: WAYLAND_DISPLAY needs XDG_RUNTIME_DIR\n", .{});
        return error.NoCompositor;
    };
    const win = app.Window.open(gpa, .device(dev), path, .{ .title = "Maps", .size = view.open_size }) catch |err| {
        print(sys.log_warning ++ "dazzle-maps: cannot open a window on {s} ({s})\n", .{ path, @errorName(err) });
        return err;
    };
    try win.setAppId("dazzle-maps");
    return win;
}

fn run(init: std.process.Init.Minimal, font_path: [*:0]const u8) !void {
    locale.current = locale.load().language;
    const gpa = std.heap.page_allocator;
    var dev = vc4.device.openRender() catch |err| {
        print(sys.log_error ++ "dazzle-maps: no GPU ({s})\n", .{@errorName(err)});
        return err;
    };
    const win = try openWindow(gpa, init, &dev);
    var width = win.width;
    var height = win.height;

    var globe_gpu = try globe.GlobeGpu.init(gpa, dev);
    defer globe_gpu.deinit(dev);

    var tile_manager = tiles.TileManager.init(gpa);
    defer tile_manager.deinit();

    var f = loadFont(gpa, font_path);
    const window_ui = try ui.Ui.create(gpa, if (f) |*fnt| fnt else null);
    window_ui.clipboard = .of(&win.clipboard);
    try window_ui.attachGpu(dev);

    var dirty = true;
    var idle = false;
    var suspended = false;
    var controls: app.Controls = .{ .win = win };
    win.setMinSize(view.min_size[0], view.min_size[1]);

    while (true) {
        const waited = if (idle) blk: {
            const until = if (window_ui.needs_frame and !win.suspended)
                sys.nowNs() + 16 * std.time.ns_per_ms
            else
                sys.nowNs() + 100 * std.time.ns_per_ms;
            break :blk win.wait(@max(until -| sys.nowNs(), std.time.ns_per_ms));
        } else win.poll();

        waited catch |err| {
            if (err == error.ServerError) print(sys.log_error ++ "dazzle-maps: compositor error: {s}\n", .{win.conn.errorMessage()});
            return err;
        };

        if (win.closed or controls.quit) return;

        if (try win.applyConfigure()) |size| {
            width = size[0];
            height = size[1];
            dirty = true;
        }

        if (win.suspended != suspended) {
            suspended = win.suspended;
            if (suspended) win.releaseSpareBuffers() else dirty = true;
        }

        const frame_start = sys.nowNs();
        for (win.takeInput()) |e| switch (e) {
            .motion => |pos| {
                window_ui.pointerMotion(pos);
                dirty = true;
            },
            .button => |b| {
                window_ui.pointerButton(b.pos, b.code, b.pressed);
                dirty = true;
            },
            .scroll => |sc| {
                window_ui.pointerScroll(sc.pos, sc.dx, sc.dy);
                dirty = true;
            },
            .leave => window_ui.pointerLeave(),
            .touch_down => |t| window_ui.touchDown(t.id, t.pos),
            .touch_motion => |t| window_ui.touchMotion(t.id, t.pos),
            .touch_up => |id| window_ui.touchUp(id),
            .touch_cancel => window_ui.touchCancel(),
            .key, .relative_motion, .pointer_locked => {},
        };

        idle = true;
        if (!suspended and (dirty or window_ui.needs_frame)) {
            dirty = false;
            window_ui.fullscreen = win.fullscreen;
            window_ui.frame(width, height, frame_start, view.Maps{
                .globe_gpu = &globe_gpu,
                .tile_manager = &tile_manager,
                .on_close = .of(&controls, app.Controls.close),
                .on_maximize = .of(&controls, app.Controls.toggleMaximized),
                .on_drag = .of(&controls, app.Controls.drag),
                .maximized = win.maximized,
                .width = @floatFromInt(width),
            });

            if (window_ui.changed()) {
                idle = false;
                const target = try win.beginFrame();
                const region = window_ui.repaint(win.bufferAge());
                frame.begin(target, .{ .clear = background });
                ui.Ui.limit(&frame, &region);
                try window_ui.render(&frame, win.flusher());
                try win.render(&frame);
                var damage: [ui.damage.Region.max_rects]vc4.render.Viewport = undefined;
                const changed = window_ui.damaged();
                for (changed, damage[0..changed.len]) |r, *v| v.* = .{ .x = @intFromFloat(r.x), .y = @intFromFloat(r.y), .width = @intFromFloat(r.w), .height = @intFromFloat(r.h) };
                try win.showDamaged(damage[0..changed.len]);
            }
        }
    }
}

test {
    _ = map_data;
    _ = globe;
    _ = tiles;
    _ = view;
}
