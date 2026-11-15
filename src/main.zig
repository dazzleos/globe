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
const app = @import("app");

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
    // Frames are left with the GPU: the next is made while it draws one.
    try host.init(gpa, init.io, init.minimal.environ, .{ .app_id = "dazzle-maps", .pipelined = true });
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

    // Where the frames' time goes, said every 10 s while frames are drawn
    // (when the globe turns or zooms): see `Timing`.
    var timing: Timing = .{ .since = sys.nowNs(), .waited_ns = app.window.gpu_waited_ns };
    while (true) {
        const started = sys.nowNs();
        const going = try host.step(std.math.maxInt(u64));
        timing.add(sys.nowNs() - started, host.renderer.takeStats(), view.takeStats(), globe_gpu.stats);
        if (!going) return;
        timing.reportEvery(10 * std.time.ns_per_s, app.window.gpu_waited_ns);
    }
}

/// The frames' time: kete's step (laying out and painting the window,
/// recording the frame's draws, waiting for the GPU to draw it and for the
/// shell to take it), and of that, the overlays' painting (projecting
/// labels, on the CPU), the recording, handing the frame to the GPU, and
/// waiting for it (frames are pipelined: the next is made while the GPU
/// draws one, which is waited for only if it has not finished by then).
const Timing = struct {
    since: u64,
    /// `app.window.gpu_waited_ns` when this began.
    waited_ns: u64,
    frames: u32 = 0,
    step_ns: u64 = 0,
    record_ns: u64 = 0,
    gpu_ns: u64 = 0,
    overlays: view.Stats = .{},
    globe: globe.DrawStats = .{},

    fn add(t: *Timing, step_ns: u64, r: kete_vc4.renderer.Stats, v: view.Stats, g: globe.DrawStats) void {
        if (r.frames == 0) return;
        t.globe = g;
        t.frames += r.frames;
        t.step_ns += step_ns;
        t.record_ns += r.cpu_ns;
        t.gpu_ns += r.gpu_ns;
        t.overlays.paints += v.paints;
        t.overlays.paint_ns += v.paint_ns;
        t.overlays.points += v.points;
        t.overlays.labels += v.labels;
        t.overlays.high_detail = v.high_detail;
    }

    fn reportEvery(t: *Timing, period_ns: u64, waited_ns: u64) void {
        const now = sys.nowNs();
        if (now - t.since < period_ns) return;
        defer t.* = .{ .since = now, .waited_ns = waited_ns };
        if (t.frames == 0) return;
        const n: f64 = @floatFromInt(t.frames);
        const ms = struct {
            fn per(ns: u64, frames: f64) f64 {
                return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms / frames;
            }
        }.per;
        const p: f64 = @floatFromInt(@max(t.overlays.paints, 1));
        print("dazzle-maps: {d} frames ({d:.1} a second), {s} detail, {d} cells ({d} draws, {d}k triangles); per frame: step {d:.1} ms (overlays painted {d:.1} ms: {d:.0} points, {d:.0} labels; recording {d:.1} ms, handing over {d:.1} ms, waiting for the GPU {d:.1} ms)\n", .{
            t.frames,
            n / (@as(f64, @floatFromInt(now - t.since)) / std.time.ns_per_s),
            if (t.overlays.high_detail) "high" else "low",
            t.globe.cells,
            t.globe.draws,
            t.globe.triangles / 1000,
            ms(t.step_ns, n),
            ms(t.overlays.paint_ns, p),
            @as(f64, @floatFromInt(t.overlays.points)) / p,
            @as(f64, @floatFromInt(t.overlays.labels)) / p,
            ms(t.record_ns, n),
            ms(t.gpu_ns, n),
            ms(waited_ns -% t.waited_ns, n),
        });
    }
};

test {
    _ = map_data;
    _ = globe;
    _ = view;
}
