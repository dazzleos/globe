//! Maps: an interactive 3D political globe application for Dazzle, showing
//! the Earth rendered with embedded Natural Earth vectors.
//!
//!     dazzle-maps [font.ttf]
//!
//! Runs until its window is closed.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const locale = @import("locale");
const font = @import("font");
const ui = @import("ui");
const build_info = @import("build_info");

const map_data = @import("map_data");
const globe = @import("globe.zig");
const view = @import("view.zig");

const print = sys.print;

const background = 0xff0b101b;

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

fn run(init: std.process.Init.Minimal, font_path: [*:0]const u8) !void {
    locale.current = locale.load().language;
    const gpa = std.heap.page_allocator;
    const a = try ui.App.open(gpa, init.environ, .{
        .title = "Maps",
        .app_id = "dazzle-maps",
        .size = view.open_size,
        .min_size = view.min_size,
        .font_path = font_path,
        .clear_color = background,
    });
    defer a.close();

    var globe_gpu = try globe.GlobeGpu.init(gpa, a.dev);
    defer globe_gpu.deinit(a.dev);

    while (try a.step(100 * std.time.ns_per_ms)) {
        const frame_start = sys.nowNs();
        a.takeInput();

        try a.draw(frame_start, view.Maps{
            .globe_gpu = &globe_gpu,
        });
    }
}

test {
    _ = map_data;
    _ = globe;
    _ = view;
}
