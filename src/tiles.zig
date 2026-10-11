//! Web map tile calculations and remote tile access for Dazzle Maps.
//!
//! Implements Slippy Map (XYZ / Web Mercator) tile coordinates,
//! bounding box projections, URL templating, in-memory caching,
//! and graceful offline fallback.

const std = @import("std");
const map_data = @import("map_data.zig");

pub const TileCoord = struct {
    z: u8,
    x: u32,
    y: u32,

    pub fn eql(a: TileCoord, b: TileCoord) bool {
        return a.z == b.z and a.x == b.x and a.y == b.y;
    }
};

pub const TileBounds = struct {
    min_lat: f32,
    max_lat: f32,
    min_lon: f32,
    max_lon: f32,

    pub fn contains(b: TileBounds, c: map_data.Coord) bool {
        return c.lat >= b.min_lat and c.lat <= b.max_lat and c.lon >= b.min_lon and c.lon <= b.max_lon;
    }
};

/// Converts geographic coordinates (lat, lon in degrees) to an XYZ tile index at zoom level `z`.
pub fn latLonToTile(lat_deg: f32, lon_deg: f32, z: u8) TileCoord {
    const clamped_lat = std.math.clamp(lat_deg, -85.0511, 85.0511);
    const clamped_lon = std.math.clamp(lon_deg, -180.0, 180.0);

    const n: f32 = @floatFromInt(@as(u32, 1) << @intCast(z));
    const x = @as(u32, @intFromFloat(std.math.clamp((clamped_lon + 180.0) / 360.0 * n, 0.0, n - 1.0)));

    const lat_rad = clamped_lat * (std.math.pi / 180.0);
    // Web Mercator formula: y = (1 - ln(tan(lat) + sec(lat)) / pi) / 2 * n
    const sin_lat = @sin(lat_rad);
    const merc_y = 0.5 - (@log((1.0 + sin_lat) / (1.0 - sin_lat)) / (4.0 * std.math.pi));
    const y = @as(u32, @intFromFloat(std.math.clamp(merc_y * n, 0.0, n - 1.0)));

    return .{ .z = z, .x = x, .y = y };
}

/// Computes the geographic bounding box of an XYZ tile.
pub fn tileToBounds(tile: TileCoord) TileBounds {
    const n: f32 = @floatFromInt(@as(u32, 1) << @intCast(tile.z));
    const x_f: f32 = @floatFromInt(tile.x);
    const y_f: f32 = @floatFromInt(tile.y);

    const min_lon = (x_f / n) * 360.0 - 180.0;
    const max_lon = ((x_f + 1.0) / n) * 360.0 - 180.0;

    const latFromY = struct {
        fn call(y_val: f32, count: f32) f32 {
            const sinh_val = std.math.sinh(std.math.pi * (1.0 - 2.0 * y_val / count));
            return std.math.atan(sinh_val) * (180.0 / std.math.pi);
        }
    }.call;

    const max_lat = latFromY(y_f, n);
    const min_lat = latFromY(y_f + 1.0, n);

    return .{
        .min_lat = min_lat,
        .max_lat = max_lat,
        .min_lon = min_lon,
        .max_lon = max_lon,
    };
}

/// Default OpenStreetMap tile server template.
pub const osm_tile_server = "https://tile.openstreetmap.org";

/// Formats the URL for fetching a tile.
pub fn formatTileUrl(buf: []u8, server: []const u8, tile: TileCoord) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{d}/{d}/{d}.png", .{ server, tile.z, tile.x, tile.y }) catch null;
}

pub const TileStatus = enum {
    empty,
    downloading,
    ready,
    failed,
};

pub const CachedTile = struct {
    coord: TileCoord,
    status: TileStatus = .empty,
    last_used: u64 = 0,
    pixels: ?[]u32 = null,
};

pub const max_cached_tiles = 32;

/// In-memory tile cache and downloader manager.
pub const TileManager = struct {
    allocator: std.mem.Allocator,
    cache: [max_cached_tiles]CachedTile = [_]CachedTile{.{ .coord = .{ .z = 0, .x = 0, .y = 0 } }} ** max_cached_tiles,
    count: usize = 0,
    server: []const u8 = osm_tile_server,
    enabled: bool = false,
    download_failures: usize = 0,
    download_successes: usize = 0,

    pub fn init(allocator: std.mem.Allocator) TileManager {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(tm: *TileManager) void {
        for (&tm.cache) |*tile| {
            if (tile.pixels) |p| tm.allocator.free(p);
            tile.pixels = null;
        }
    }

    /// Finds a cached tile, if present.
    pub fn get(tm: *const TileManager, coord: TileCoord) ?*const CachedTile {
        for (tm.cache[0..tm.count]) |*tile| {
            if (tile.coord.eql(coord)) return tile;
        }
        return null;
    }

    /// Marks a tile requested. If not already cached or downloading, prepares an entry.
    pub fn request(tm: *TileManager, coord: TileCoord, now_ns: u64) void {
        for (tm.cache[0..tm.count]) |*tile| {
            if (tile.coord.eql(coord)) {
                tile.last_used = now_ns;
                return;
            }
        }

        // Allocate new slot or evict oldest:
        var slot_idx: usize = 0;
        if (tm.count < max_cached_tiles) {
            slot_idx = tm.count;
            tm.count += 1;
        } else {
            // Find LRU entry
            var oldest_time = tm.cache[0].last_used;
            for (tm.cache[1..], 1..) |t, i| {
                if (t.last_used < oldest_time) {
                    oldest_time = t.last_used;
                    slot_idx = i;
                }
            }
            if (tm.cache[slot_idx].pixels) |p| {
                tm.allocator.free(p);
                tm.cache[slot_idx].pixels = null;
            }
        }

        tm.cache[slot_idx] = .{
            .coord = coord,
            .status = .downloading,
            .last_used = now_ns,
            .pixels = null,
        };
    }

    /// Marks a tile as downloaded and decoded.
    pub fn putReady(tm: *TileManager, coord: TileCoord, pixels: []u32, now_ns: u64) void {
        for (tm.cache[0..tm.count]) |*tile| {
            if (tile.coord.eql(coord)) {
                if (tile.pixels) |p| tm.allocator.free(p);
                tile.pixels = pixels;
                tile.status = .ready;
                tile.last_used = now_ns;
                tm.download_successes += 1;
                return;
            }
        }
    }

    /// Marks a tile download failed (e.g. offline).
    pub fn markFailed(tm: *TileManager, coord: TileCoord) void {
        for (tm.cache[0..tm.count]) |*tile| {
            if (tile.coord.eql(coord)) {
                tile.status = .failed;
                tm.download_failures += 1;
                return;
            }
        }
    }

    /// Returns a human-readable network status string.
    pub fn statusText(tm: *const TileManager, buf: []u8) []const u8 {
        if (!tm.enabled) return "Offline (Built-in Map)";
        if (tm.download_failures > 0 and tm.download_successes == 0) {
            return "Tile server unreachable (using offline map)";
        }
        return std.fmt.bufPrint(buf, "Online ({d} tiles cached)", .{tm.download_successes}) catch "Online";
    }
};

const testing = std.testing;

test "latLonToTile for London" {
    // London: lat 51.5074, lon -0.1278
    // At zoom 0: tile is (0, 0, 0)
    const t0 = latLonToTile(51.5074, -0.1278, 0);
    try testing.expectEqual(@as(u32, 0), t0.x);
    try testing.expectEqual(@as(u32, 0), t0.y);

    // At zoom 1: tile is (1, 0, 0)
    const t1 = latLonToTile(51.5074, -0.1278, 1);
    try testing.expectEqual(@as(u32, 0), t1.x);
    try testing.expectEqual(@as(u32, 0), t1.y);

    // At zoom 2: tile is (2, 1, 1)
    const t2 = latLonToTile(51.5074, -0.1278, 2);
    try testing.expectEqual(@as(u32, 1), t2.x);
    try testing.expectEqual(@as(u32, 1), t2.y);
}

test "tile bounds roundtrip" {
    const tile = TileCoord{ .z = 2, .x = 1, .y = 1 };
    const bounds = tileToBounds(tile);
    // Bounds should span [-90, 0] lon
    try testing.expectApproxEqAbs(-90.0, bounds.min_lon, 1e-2);
    try testing.expectApproxEqAbs(0.0, bounds.max_lon, 1e-2);
    try testing.expect(bounds.contains(.{ .lat = 51.5074, .lon = -0.1278 }));
}

test "tile URL formatting" {
    var buf: [128]u8 = undefined;
    const url = formatTileUrl(&buf, osm_tile_server, .{ .z = 3, .x = 4, .y = 2 });
    try testing.expect(url != null);
    try testing.expectEqualStrings("https://tile.openstreetmap.org/3/4/2.png", url.?);
}
