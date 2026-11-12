//! Maps: an interactive 3D political globe application for Dazzle, showing
//! the Earth rendered with embedded Natural Earth vectors.
//!
//!     dazzle-maps
//!
//! Runs until its window is closed.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const kete = @import("kete");
const kete_vc4 = @import("kete_vc4");
const build_info = @import("build_info");

const map_data = @import("map_data");
const globe = @import("globe.zig");
const view = @import("view.zig");

const print = sys.print;

const background = 0xff0b101b;

pub fn main(init: std.process.Init) u8 {
    sys.logToKmsgIfStderr();
    print("dazzle: maps (build {s}) running as uid {d}\n", .{ build_info.commit, linux.getuid() });

    run(init) catch |err| {
        print(sys.log_error ++ "dazzle-maps: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

/// The window's root: the globe, drawn by the GPU.
const Root = struct {
    globe_gpu: *globe.GlobeGpu,

    pub fn build(r: *const Root, cx: *kete.BuildContext) kete.Widget {
        return cx.make(view.Maps{ .globe_gpu = r.globe_gpu });
    }
};

fn run(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    var host: kete_vc4.Host = undefined;
    try host.init(gpa, init.io, init.minimal.environ, .{ .app_id = "dazzle-maps" });
    defer host.deinit();

    var globe_gpu = try globe.GlobeGpu.init(gpa, host.dev);
    defer globe_gpu.deinit(host.dev);

    const root: Root = .{ .globe_gpu = &globe_gpu };
    _ = try host.app.openWindow(.{
        .title = "Maps",
        .root = .of(&root),
        .size = view.open_size,
        .min_size = view.min_size,
        .clear_color = background,
        .on_close_request = .close,
    });

    while (try host.step(std.math.maxInt(u64))) {}
}

test {
    _ = map_data;
    _ = globe;
    _ = view;
}
