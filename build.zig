//! Globe, an app for exploring the Earth on a 3D globe, for Dazzle: built
//! with Dazzle's modules and tools (see Dazzle's build.zig, `addApp`).
//!
//!     zig build                 the program, and its archive and catalogue (zig-out/apps)
//!     zig build test            its tests, on this computer
//!
//! With a Dazzle (or kete) checkout of your own beside it:
//! `zig build --fork=../dazzle`.

const std = @import("std");
const dazzle = @import("dazzle");

pub fn build(b: *std.Build) void {
    // Its program keeps the name it had as Maps, so what is installed
    // updates.
    const app = dazzle.addApp(b, .{
        .name = "dazzle-maps",
        .icon = .public,
        .title = "Globe",
        .description = "Explore the Earth on a 3D globe",
        .about = "Explore the Earth on a 3D globe: spin it, zoom in to countries and see their names and borders.",
        .shaders = &.{
            .{ .source = "src/shaders/globe.zig", .args = &.{"--depth-test"} },
            .{ .source = "src/shaders/globe_lines.zig", .args = &.{"--blend=source-over"} },
        },
    });

    // The countries: Natural Earth's 110m and 50m Admin-0 Countries,
    // triangulated and subdivided at build time (tools/mkmap.zig):
    // `@import("map_data")`.
    const mkmap = b.addExecutable(.{
        .name = "mkmap",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mkmap.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const run = b.addRunArtifact(mkmap);
    run.addFileArg(b.path("src/data/ne_110m_admin_0_countries.geojson"));
    run.addFileArg(b.path("src/data/ne_50m_admin_0_countries.geojson"));
    const map_data = run.addOutputFileArg("map_data.zig");
    for ([_]*std.Build.Module{ app.module, app.host_module }) |m| m.addAnonymousImport("map_data", .{ .root_source_file = map_data });

    // mkmap's own tests, with the app's.
    const tool_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/mkmap.zig"),
        .target = b.graph.host,
    }) });
    b.top_level_steps.get("test").?.step.dependOn(&b.addRunArtifact(tool_tests).step);
}
