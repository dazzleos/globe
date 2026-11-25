//! Makes the Globe app's embedded Natural Earth vector dataset (`map_data.zig`)
//! from Natural Earth's 110m Admin-0 Countries GeoJSON (`ne_110m_admin_0_countries.geojson`).
//!
//!     mkmap <ne_110m_admin_0_countries.geojson> <map_data.zig>
//!
//! Parses every country's `Polygon` or `MultiPolygon` geometry, assigns its
//! MapLibre `globe.json` political color by `ADM0_A3`, triangulates each ring
//! with ear-clipping, subdivides large triangles so they follow the 3D sphere's
//! curvature without poking below the unit ocean sphere, deduplicates shared
//! edges to separate coastlines from international boundaries, and extracts
//! country label anchor points.

const std = @import("std");

pub const country_palette = [6]u32{
    0xFFD6C7FF,
    0xFFEBCA8A,
    0xFFC1E599,
    0xFFE7E58F,
    0xFF98DDA1,
    0xFFEAB38F,
};

const group0 = [_][]const u8{
    "ARM", "ATG", "AUS", "BTN", "CAN", "COG", "CZE", "GHA", "GIN", "HTI",
    "ISL", "JOR", "KHM", "KOR", "LVA", "MLT", "MNE", "MOZ", "NAM", "NER",
    "PRK", "PRT", "SEN", "SOL", "SOM", "SSD", "SXM", "SYC", "TJK", "TTO",
    "TUN", "UKR", "UZB", "VUT", "ZMB",
};

const group1 = [_][]const u8{
    "AZE", "BGD", "CHL", "CMR", "CSI", "DEU", "DJI", "GUY", "HUN", "IOA",
    "JAM", "LBN", "LBY", "LSO", "MDG", "MKD", "MNG", "MRT", "NIU", "NZL",
    "PCN", "PYF", "SAU", "SHN", "STP", "TGO", "UGA", "uzb",
};

const group2 = [_][]const u8{
    "AGO", "ASM", "BDI", "BHS", "BLZ", "BRA", "CHN", "COK", "COM", "CPV",
    "CRI", "CUB", "CYP", "DNK", "DOM", "ERI", "ESH", "ESP", "EST", "ETH",
    "FIN", "FJI", "FLK", "FSM", "GAB", "GMB", "GNQ", "GRD", "HMD", "HRV",
    "IMN", "IND", "IRN", "ITA", "KIR", "KNA", "LBR", "LCA", "LKA", "MAF",
    "MDV", "MEX", "MHL", "MLI", "MMR", "MUS", "MYS", "MYT", "NFK", "NGA",
    "NIC", "NLD", "NOR", "NPL", "NRU", "OMN", "PAK", "PAN", "PHL", "PLW",
    "PNG", "PRI", "QAT", "REU", "SDN", "SGP", "SLB", "SLV", "SPM", "SUR",
    "SVK", "SVN", "SWE", "SWZ", "SYR", "TCA", "TKL", "TLS", "TON", "TUR",
    "TUV", "TZA", "UMI", "USA", "VCT", "VEN", "VGB", "VIR", "WLF", "WSM",
    "YEM", "ZAF",
};

const group3 = [_][]const u8{
    "AFG", "ALB", "AND", "ARE", "ARG", "AUT", "BEL", "BFA", "BGR", "BIH",
    "BLR", "BMU", "BOL", "BRB", "BRN", "CAF", "CHE", "CIV", "CLP", "COL",
    "CUW", "CYM", "CYN", "DMA", "DZA", "ECU", "EGY", "FRA", "FRO", "GAZ",
    "GBR", "GEO", "GGY", "GIB", "GLP", "GNB", "GRC", "GTM", "GUF", "GUM",
    "HKG", "HND", "IDN", "IRL", "IRQ", "ISR", "JEY", "JPN", "KAS", "KAZ",
    "KEN", "KGZ", "KWT", "LAO", "LIE", "LTU", "LUX", "MAC", "MAR", "MCO",
    "MDA", "MNP", "MSR", "MTQ", "MWI", "NCL", "NIR", "PER", "PGA", "POL",
    "PRY", "PSE", "ROU", "RUS", "RWA", "SCT", "SGS", "SJM", "SLE", "SMR",
    "SRB", "TCD", "THA", "TKM", "TWN", "URY", "VAT", "VNM", "ZWE",
};

const group4 = [_][]const u8{
    "ATA", "GRL",
};

fn inGroup(code: []const u8, list: []const []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, code, item)) return true;
    }
    return false;
}

pub fn getCountryColorIdx(adm0_a3: []const u8) u8 {
    if (inGroup(adm0_a3, &group0)) return 0;
    if (inGroup(adm0_a3, &group1)) return 1;
    if (inGroup(adm0_a3, &group2)) return 2;
    if (inGroup(adm0_a3, &group3)) return 3;
    if (inGroup(adm0_a3, &group4)) return 4;
    return 5;
}

const Point2f = [2]f64;
const QuantPt = [2]i16;
const Tri = [3]Point2f;

fn quantPt(lon: f64, lat: f64) QuantPt {
    const qlon = std.math.clamp(@round(lon * 100.0), -18000.0, 18000.0);
    const qlat = std.math.clamp(@round(lat * 100.0), -9000.0, 9000.0);
    return .{ @intFromFloat(qlon), @intFromFloat(qlat) };
}

fn signedArea(pts: []const Point2f) f64 {
    var area: f64 = 0.0;
    const n = pts.len;
    for (0..n) |i| {
        const p1 = pts[i];
        const p2 = pts[(i + 1) % n];
        area += (p1[0] * p2[1] - p2[0] * p1[1]);
    }
    return 0.5 * area;
}

fn cross2d(o: Point2f, a: Point2f, b: Point2f) f64 {
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
}

fn pointInTri(p: Point2f, a: Point2f, b: Point2f, c: Point2f) bool {
    const d1 = cross2d(a, b, p);
    const d2 = cross2d(b, c, p);
    const d3 = cross2d(c, a, p);
    return (d1 >= -1e-9) and (d2 >= -1e-9) and (d3 >= -1e-9);
}

pub fn earClip(gpa: std.mem.Allocator, ring: []const Point2f, out: *std.ArrayList(Tri)) !void {
    if (ring.len < 3) return;
    var pts: std.ArrayList(Point2f) = .empty;
    defer pts.deinit(gpa);

    const end_len = if (ring.len >= 2 and @abs(ring[0][0] - ring[ring.len - 1][0]) <= 1e-6 and @abs(ring[0][1] - ring[ring.len - 1][1]) <= 1e-6)
        ring.len - 1
    else
        ring.len;

    for (ring[0..end_len]) |p| {
        if (pts.items.len == 0 or @abs(pts.items[pts.items.len - 1][0] - p[0]) > 1e-6 or @abs(pts.items[pts.items.len - 1][1] - p[1]) > 1e-6) {
            try pts.append(gpa, p);
        }
    }
    if (pts.items.len >= 2 and @abs(pts.items[0][0] - pts.items[pts.items.len - 1][0]) <= 1e-6 and @abs(pts.items[0][1] - pts.items[pts.items.len - 1][1]) <= 1e-6) {
        _ = pts.pop();
    }
    if (pts.items.len < 3) return;

    if (signedArea(pts.items) < 0) {
        std.mem.reverse(Point2f, pts.items);
    }

    var idxs: std.ArrayList(usize) = .empty;
    defer idxs.deinit(gpa);
    for (0..pts.items.len) |i| try idxs.append(gpa, i);

    var cur: usize = 0;
    var guard: usize = 0;
    const max_guard = pts.items.len * 4 + 100;
    while (idxs.items.len > 3 and guard < max_guard) {
        guard += 1;
        var ear_found = false;
        const m = idxs.items.len;
        for (0..m) |step| {
            const i = (cur + step) % m;
            const i_prev = idxs.items[(i + m - 1) % m];
            const i_curr = idxs.items[i];
            const i_next = idxs.items[(i + 1) % m];
            const a = pts.items[i_prev];
            const b = pts.items[i_curr];
            const c = pts.items[i_next];
            if (cross2d(a, b, c) <= 1e-9) continue;

            const min_x = @min(a[0], @min(b[0], c[0]));
            const max_x = @max(a[0], @max(b[0], c[0]));
            const min_y = @min(a[1], @min(b[1], c[1]));
            const max_y = @max(a[1], @max(b[1], c[1]));

            var inside = false;
            for (0..m) |j| {
                if (j == (i + m - 1) % m or j == i or j == (i + 1) % m) continue;
                const p = pts.items[idxs.items[j]];
                if (p[0] < min_x or p[0] > max_x or p[1] < min_y or p[1] > max_y) continue;
                if (pointInTri(p, a, b, c)) {
                    inside = true;
                    break;
                }
            }
            if (!inside) {
                try out.append(gpa, .{ a, b, c });
                _ = idxs.orderedRemove(i);
                cur = if (i == 0) 0 else (i - 1) % idxs.items.len;
                ear_found = true;
                break;
            }
        }
        if (!ear_found) {
            for (0..m) |step| {
                const i = (cur + step) % m;
                const i_prev = idxs.items[(i + m - 1) % m];
                const i_curr = idxs.items[i];
                const i_next = idxs.items[(i + 1) % m];
                const a = pts.items[i_prev];
                const b = pts.items[i_curr];
                const c = pts.items[i_next];
                if (cross2d(a, b, c) > 0) {
                    try out.append(gpa, .{ a, b, c });
                    _ = idxs.orderedRemove(i);
                    cur = if (i == 0) 0 else (i - 1) % idxs.items.len;
                    ear_found = true;
                    break;
                }
            }
            if (!ear_found) {
                const a = pts.items[idxs.items[0]];
                const b = pts.items[idxs.items[1]];
                const c = pts.items[idxs.items[2]];
                try out.append(gpa, .{ a, b, c });
                _ = idxs.orderedRemove(1);
                cur = 0;
            }
        }
    }
    if (idxs.items.len == 3) {
        try out.append(gpa, .{
            pts.items[idxs.items[0]],
            pts.items[idxs.items[1]],
            pts.items[idxs.items[2]],
        });
    }
}

fn sphereDegDist(p1: Point2f, p2: Point2f) f64 {
    const mean_lat = (0.5 * (p1[1] + p2[1])) * (std.math.pi / 180.0);
    const dlon = (p1[0] - p2[0]) * @max(0.15, @cos(mean_lat));
    const dlat = p1[1] - p2[1];
    return std.math.hypot(dlon, dlat);
}

fn subdivideTri(gpa: std.mem.Allocator, a: Point2f, b: Point2f, c: Point2f, max_deg: f64, depth: u32, out: *std.ArrayList(Tri)) !void {
    if (depth >= 6) {
        try out.append(gpa, .{ a, b, c });
        return;
    }
    const ab = sphereDegDist(a, b);
    const bc = sphereDegDist(b, c);
    const ca = sphereDegDist(c, a);
    const longest = @max(ab, @max(bc, ca));
    if (longest <= max_deg) {
        try out.append(gpa, .{ a, b, c });
        return;
    }
    if (ab >= bc and ab >= ca) {
        const mid: Point2f = .{ (a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5 };
        try subdivideTri(gpa, a, mid, c, max_deg, depth + 1, out);
        try subdivideTri(gpa, mid, b, c, max_deg, depth + 1, out);
    } else if (bc >= ab and bc >= ca) {
        const mid: Point2f = .{ (b[0] + c[0]) * 0.5, (b[1] + c[1]) * 0.5 };
        try subdivideTri(gpa, a, b, mid, max_deg, depth + 1, out);
        try subdivideTri(gpa, a, mid, c, max_deg, depth + 1, out);
    } else {
        const mid: Point2f = .{ (c[0] + a[0]) * 0.5, (c[1] + a[1]) * 0.5 };
        try subdivideTri(gpa, a, b, mid, max_deg, depth + 1, out);
        try subdivideTri(gpa, mid, b, c, max_deg, depth + 1, out);
    }
}

const EdgeKey = struct {
    u: QuantPt,
    v: QuantPt,

    fn make(a: QuantPt, b: QuantPt) EdgeKey {
        if (a[0] < b[0] or (a[0] == b[0] and a[1] < b[1])) {
            return .{ .u = a, .v = b };
        }
        return .{ .u = b, .v = a };
    }
};

const VertKey = struct {
    lon_cd: i16,
    lat_cd: i16,
    color_idx: u8,
};

const CountryRing = struct {
    feat_idx: u32,
    color_idx: u8,
    outer: []const Point2f,
    q_ring: []const QuantPt,
};

const LabelInfo = struct {
    name: []const u8,
    lat: f64,
    lon: f64,
    rank: u8,
};

const Span = struct { start: u32, len: u16 };

const BatchInfo = struct {
    vert_start: u32,
    vert_count: u16,
    idx_start: u32,
    idx_count: u32,
};

const LodDataset = struct {
    verts: []const VertKey,
    tri_indices: []const [3]u16,
    batches: []const BatchInfo,
    coast_pts: []const QuantPt,
    coast_spans: []const Span,
    border_pts: []const QuantPt,
    border_spans: []const Span,
    labels: []const LabelInfo,
};

fn jsonNumber(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Each country's colour (its index in `country_palette`), by ADM0_A3, so
/// that no two countries sharing a border (an edge of their outlines, in
/// any of `datasets`) have the same one: the colour MapLibre gives it
/// (`getCountryColorIdx`) where none of its neighbours has that, otherwise
/// the first free one. Countries are coloured most constrained first
/// (DSatur), which a map's few colours always suffice for here.
pub fn countryColors(arena: std.mem.Allocator, datasets: []const []const u8) !std.StringHashMapUnmanaged(u8) {
    var ids: std.StringHashMapUnmanaged(u16) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var owner: std.AutoHashMapUnmanaged(EdgeKey, u16) = .empty;
    var pairs: std.AutoHashMapUnmanaged([2]u16, void) = .empty;
    for (datasets) |bytes| {
        owner.clearRetainingCapacity();
        const parsed = try std.json.parseFromSlice(std.json.Value, arena, bytes, .{});
        for (parsed.value.object.get("features").?.array.items) |feat_val| {
            const feat = feat_val.object;
            const props = feat.get("properties").?.object;
            const adm0 = jsonString(props, "ADM0_A3") orelse jsonString(props, "ISO_A3") orelse continue;
            const gop = try ids.getOrPut(arena, adm0);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(names.items.len);
                try names.append(arena, adm0);
            }
            const id = gop.value_ptr.*;
            const geom = feat.get("geometry").?.object;
            const coords = geom.get("coordinates").?.array.items;
            // A MultiPolygon's polygons, or a Polygon (its rings).
            const multi = std.mem.eql(u8, geom.get("type").?.string, "MultiPolygon");
            for (0..if (multi) coords.len else 1) |pi| for (if (multi) coords[pi].array.items else coords) |ring| {
                var prev: ?QuantPt = null;
                for (ring.array.items) |pt| {
                    const pair = pt.array.items;
                    if (pair.len < 2) continue;
                    const q = quantPt(jsonNumber(pair[0]) orelse continue, jsonNumber(pair[1]) orelse continue);
                    if (prev) |p| if (p[0] != q[0] or p[1] != q[1]) {
                        const e = try owner.getOrPut(arena, EdgeKey.make(p, q));
                        if (!e.found_existing) {
                            e.value_ptr.* = id;
                        } else if (e.value_ptr.* != id) {
                            const o = e.value_ptr.*;
                            try pairs.put(arena, .{ @min(o, id), @max(o, id) }, {});
                        }
                    };
                    prev = q;
                }
            };
        }
    }
    const n = names.items.len;
    const neighbours = try arena.alloc(std.ArrayList(u16), n);
    for (neighbours) |*l| l.* = .empty;
    var it = pairs.keyIterator();
    while (it.next()) |pr| {
        try neighbours[pr[0]].append(arena, pr[1]);
        try neighbours[pr[1]].append(arena, pr[0]);
    }
    const colour = try arena.alloc(?u8, n);
    @memset(colour, null);
    for (0..n) |_| {
        // The uncoloured country with the most differently coloured
        // neighbours (then the most neighbours).
        var best: ?usize = null;
        var best_sat: usize = 0;
        for (0..n) |c| if (colour[c] == null) {
            var seen: u8 = 0;
            for (neighbours[c].items) |nb| if (colour[nb]) |k| {
                seen |= @as(u8, 1) << @intCast(k);
            };
            const sat: usize = @popCount(seen);
            if (best == null or sat > best_sat or (sat == best_sat and neighbours[c].items.len > neighbours[best.?].items.len)) {
                best = c;
                best_sat = sat;
            }
        };
        const c = best.?;
        var used: u8 = 0;
        for (neighbours[c].items) |nb| if (colour[nb]) |k| {
            used |= @as(u8, 1) << @intCast(k);
        };
        const preferred = getCountryColorIdx(names.items[c]);
        colour[c] = if (used & (@as(u8, 1) << @intCast(preferred)) == 0) preferred else for (0..country_palette.len) |k| {
            if (used & (@as(u8, 1) << @intCast(k)) == 0) break @intCast(k);
        } else return error.TooFewColours;
    }
    var out: std.StringHashMapUnmanaged(u8) = .empty;
    for (names.items, colour) |name, k| try out.put(arena, name, k.?);
    return out;
}

fn buildDataset(arena: std.mem.Allocator, geojson_bytes: []const u8, colours: *const std.StringHashMapUnmanaged(u8)) !LodDataset {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, geojson_bytes, .{});
    const root = parsed.value.object;
    const features = root.get("features").?.array.items;

    var country_rings: std.ArrayList(CountryRing) = .empty;
    var labels: std.ArrayList(LabelInfo) = .empty;

    const EdgeOwners = struct {
        first_feat: u32,
        shared: bool = false,
    };
    var edge_owners: std.AutoHashMapUnmanaged(EdgeKey, EdgeOwners) = .empty;

    for (features, 0..) |feat_val, feat_idx_usize| {
        const feat_idx: u32 = @intCast(feat_idx_usize);
        const feat = feat_val.object;
        const props = feat.get("properties").?.object;

        const adm0 = jsonString(props, "ADM0_A3") orelse jsonString(props, "ISO_A3") orelse "";
        const name = jsonString(props, "NAME") orelse jsonString(props, "ADMIN") orelse "";
        const label_x = if (props.get("LABEL_X")) |v| jsonNumber(v) orelse 0.0 else 0.0;
        const label_y = if (props.get("LABEL_Y")) |v| jsonNumber(v) orelse 0.0 else 0.0;
        const scalerank: u8 = if (props.get("LABELRANK")) |v|
            @intFromFloat(std.math.clamp(jsonNumber(v) orelse 5.0, 1.0, 10.0))
        else
            5;
        const color_idx = colours.get(adm0) orelse getCountryColorIdx(adm0);

        if (name.len > 0 and !std.mem.eql(u8, adm0, "ATA")) {
            try labels.append(arena, .{
                .name = name,
                .lat = label_y,
                .lon = label_x,
                .rank = scalerank,
            });
        }

        const geom = feat.get("geometry").?.object;
        const geom_type = geom.get("type").?.string;
        const coords = geom.get("coordinates").?.array.items;

        if (std.mem.eql(u8, geom_type, "MultiPolygon")) {
            for (coords) |poly_val| {
                try processPolygon(arena, poly_val.array.items, feat_idx, color_idx, &country_rings, &edge_owners);
            }
        } else if (std.mem.eql(u8, geom_type, "Polygon")) {
            try processPolygon(arena, coords, feat_idx, color_idx, &country_rings, &edge_owners);
        }
    }

    var vert_map: std.AutoHashMapUnmanaged(VertKey, u16) = .empty;
    var verts: std.ArrayList(VertKey) = .empty;
    var tri_indices: std.ArrayList([3]u16) = .empty;
    var batches: std.ArrayList(BatchInfo) = .empty;
    var batch_vert_start: u32 = 0;
    var batch_idx_start: u32 = 0;

    var raw_tris: std.ArrayList(Tri) = .empty;
    var sub_tris: std.ArrayList(Tri) = .empty;

    for (country_rings.items) |cr| {
        raw_tris.clearRetainingCapacity();
        sub_tris.clearRetainingCapacity();
        try earClip(arena, cr.outer, &raw_tris);
        for (raw_tris.items) |t| {
            try subdivideTri(arena, t[0], t[1], t[2], 7.0, 0, &sub_tris);
        }
        for (sub_tris.items) |st| {
            // Keep each batch well under u16's 65535 vertex limit (leaving room for the 3321-vertex ocean sphere in batch 0):
            const max_batch_verts: usize = if (batches.items.len == 0) 56_000 else 60_000;
            if ((verts.items.len - batch_vert_start) + 3 > max_batch_verts and verts.items.len > batch_vert_start) {
                try batches.append(arena, .{
                    .vert_start = batch_vert_start,
                    .vert_count = @intCast(verts.items.len - batch_vert_start),
                    .idx_start = batch_idx_start,
                    .idx_count = @intCast(tri_indices.items.len * 3 - batch_idx_start),
                });
                vert_map.clearRetainingCapacity();
                batch_vert_start = @intCast(verts.items.len);
                batch_idx_start = @intCast(tri_indices.items.len * 3);
            }
            const v0 = try internVert(arena, &vert_map, &verts, batch_vert_start, st[0][0], st[0][1], cr.color_idx);
            const v1 = try internVert(arena, &vert_map, &verts, batch_vert_start, st[1][0], st[1][1], cr.color_idx);
            const v2 = try internVert(arena, &vert_map, &verts, batch_vert_start, st[2][0], st[2][1], cr.color_idx);
            if (v0 != v1 and v1 != v2 and v2 != v0) {
                try tri_indices.append(arena, .{ v0, v1, v2 });
            }
        }
    }
    if (verts.items.len > batch_vert_start) {
        try batches.append(arena, .{
            .vert_start = batch_vert_start,
            .vert_count = @intCast(verts.items.len - batch_vert_start),
            .idx_start = batch_idx_start,
            .idx_count = @intCast(tri_indices.items.len * 3 - batch_idx_start),
        });
    }

    var coast_pts: std.ArrayList(QuantPt) = .empty;
    var coast_spans: std.ArrayList(Span) = .empty;
    var border_pts: std.ArrayList(QuantPt) = .empty;
    var border_spans: std.ArrayList(Span) = .empty;
    var seen_border_edges: std.AutoHashMapUnmanaged(EdgeKey, void) = .empty;

    const Kind = enum { none, coast, border };
    var curr_pts: std.ArrayList(QuantPt) = .empty;

    const Flush = struct {
        fn call(
            a: std.mem.Allocator,
            kind: Kind,
            pts: *std.ArrayList(QuantPt),
            c_pts: *std.ArrayList(QuantPt),
            c_spans: *std.ArrayList(Span),
            b_pts: *std.ArrayList(QuantPt),
            b_spans: *std.ArrayList(Span),
        ) !void {
            if (pts.items.len >= 2) {
                switch (kind) {
                    .coast => {
                        try c_spans.append(a, .{ .start = @intCast(c_pts.items.len), .len = @intCast(pts.items.len) });
                        try c_pts.appendSlice(a, pts.items);
                    },
                    .border => {
                        try b_spans.append(a, .{ .start = @intCast(b_pts.items.len), .len = @intCast(pts.items.len) });
                        try b_pts.appendSlice(a, pts.items);
                    },
                    .none => {},
                }
            }
            pts.clearRetainingCapacity();
        }
    };

    for (country_rings.items) |cr| {
        var curr_kind: Kind = .none;
        curr_pts.clearRetainingCapacity();
        for (0..cr.q_ring.len - 1) |i| {
            const u = cr.q_ring[i];
            const v = cr.q_ring[i + 1];
            // Skip polar seam along -90 deg lat in Antarctica:
            if (u[1] <= -8950 and v[1] <= -8950) {
                try Flush.call(arena, curr_kind, &curr_pts, &coast_pts, &coast_spans, &border_pts, &border_spans);
                curr_kind = .none;
                continue;
            }
            // Skip anti-meridian jumps:
            if (@abs(@as(i32, u[0]) - @as(i32, v[0])) > 18000) {
                try Flush.call(arena, curr_kind, &curr_pts, &coast_pts, &coast_spans, &border_pts, &border_spans);
                curr_kind = .none;
                continue;
            }

            const key = EdgeKey.make(u, v);
            const is_border = if (edge_owners.get(key)) |eo| eo.shared else false;
            if (is_border) {
                if (seen_border_edges.contains(key)) {
                    try Flush.call(arena, curr_kind, &curr_pts, &coast_pts, &coast_spans, &border_pts, &border_spans);
                    curr_kind = .none;
                    continue;
                }
                try seen_border_edges.put(arena, key, {});
            }

            const kind: Kind = if (is_border) .border else .coast;
            if (kind != curr_kind) {
                try Flush.call(arena, curr_kind, &curr_pts, &coast_pts, &coast_spans, &border_pts, &border_spans);
                curr_kind = kind;
                try curr_pts.append(arena, u);
                try curr_pts.append(arena, v);
            } else {
                try curr_pts.append(arena, v);
            }
        }
        try Flush.call(arena, curr_kind, &curr_pts, &coast_pts, &coast_spans, &border_pts, &border_spans);
    }

    return .{
        .verts = verts.items,
        .tri_indices = tri_indices.items,
        .batches = batches.items,
        .coast_pts = coast_pts.items,
        .coast_spans = coast_spans.items,
        .border_pts = border_pts.items,
        .border_spans = border_spans.items,
        .labels = labels.items,
    };
}

fn writeDatasetArrays(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    suffix: []const u8,
    d: LodDataset,
) !void {
    try out.print(arena, "pub const country{s}_vertices = [{d}]CountryVertex{{\n", .{ suffix, d.verts.len });
    for (d.verts) |v| {
        try out.print(arena, "    .{{ .lon_cd = {d}, .lat_cd = {d}, .color_idx = {d} }},\n", .{ v.lon_cd, v.lat_cd, v.color_idx });
    }
    try out.appendSlice(arena, "};\n\n");

    try out.print(arena, "pub const country{s}_indices = [{d}]u16{{\n", .{ suffix, d.tri_indices.len * 3 });
    for (d.tri_indices) |t| {
        try out.print(arena, "    {d}, {d}, {d},\n", .{ t[0], t[1], t[2] });
    }
    try out.appendSlice(arena, "};\n\n");

    try out.print(arena, "pub const country{s}_batches = [{d}]MeshBatch{{\n", .{ suffix, d.batches.len });
    for (d.batches) |b| {
        try out.print(arena, "    .{{ .vert_start = {d}, .vert_count = {d}, .idx_start = {d}, .idx_count = {d} }},\n", .{
            b.vert_start,
            b.vert_count,
            b.idx_start,
            b.idx_count,
        });
    }
    try out.appendSlice(arena, "};\n\n");

    try out.print(arena, "pub const coastline{s}_points = [{d}][2]i16{{\n", .{ suffix, d.coast_pts.len });
    for (d.coast_pts) |p| {
        try out.print(arena, "    .{{ {d}, {d} }},\n", .{ p[0], p[1] });
    }
    try out.appendSlice(arena, "};\n\n");

    try out.print(arena, "pub const coastline{s}_spans = [{d}]LineSpan{{\n", .{ suffix, d.coast_spans.len });
    for (d.coast_spans) |sp| {
        try out.print(arena, "    .{{ .start = {d}, .len = {d} }},\n", .{ sp.start, sp.len });
    }
    try out.appendSlice(arena, "};\n\n");

    try out.print(arena, "pub const border{s}_points = [{d}][2]i16{{\n", .{ suffix, d.border_pts.len });
    for (d.border_pts) |p| {
        try out.print(arena, "    .{{ {d}, {d} }},\n", .{ p[0], p[1] });
    }
    try out.appendSlice(arena, "};\n\n");

    try out.print(arena, "pub const border{s}_spans = [{d}]LineSpan{{\n", .{ suffix, d.border_spans.len });
    for (d.border_spans) |sp| {
        try out.print(arena, "    .{{ .start = {d}, .len = {d} }},\n", .{ sp.start, sp.len });
    }
    try out.appendSlice(arena, "};\n\n");

    try out.print(arena, "pub const country{s}_labels = [{d}]CountryLabel{{\n", .{ suffix, d.labels.len });
    for (d.labels) |lbl| {
        try out.print(arena, "    .{{ .name = \"{f}\", .lat = {d:.2}, .lon = {d:.2}, .rank = {d} }},\n", .{
            std.zig.fmtString(lbl.name),
            lbl.lat,
            lbl.lon,
            lbl.rank,
        });
    }
    try out.appendSlice(arena, "};\n\n");
}

pub fn generate(arena: std.mem.Allocator, geojson_110m: []const u8) ![]u8 {
    return generateTwoLod(arena, geojson_110m, geojson_110m);
}

pub fn generateTwoLod(arena: std.mem.Allocator, geojson_110m: []const u8, geojson_50m: []const u8) ![]u8 {
    // One colouring for both, so a country keeps its colour as the
    // detail changes.
    const colours = try countryColors(arena, &.{ geojson_110m, geojson_50m });
    const lod_110m = try buildDataset(arena, geojson_110m, &colours);
    const lod_50m = if (geojson_50m.ptr == geojson_110m.ptr and geojson_50m.len == geojson_110m.len)
        lod_110m
    else
        try buildDataset(arena, geojson_50m, &colours);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena,
        \\//! Natural Earth 110m and 50m Admin-0 Countries vector datasets and MapLibre
        \\//! globe color styling (generated at build time by tools/mkmap.zig).
        \\
        \\pub const Coord = struct {
        \\    lat: f32,
        \\    lon: f32,
        \\};
        \\
        \\/// Ocean fill color (#D8F2FF) from MapLibre's Natural Earth globe style.
        \\pub const ocean_color: u32 = 0xFFD8F2FF;
        \\
        \\/// Coastline stroke color (#198EC8) from MapLibre's Natural Earth globe style.
        \\pub const coastline_color: u32 = 0xFF198EC8;
        \\
        \\/// Country boundary stroke color (#FFFFFF) from MapLibre's Natural Earth globe style.
        \\pub const boundary_color: u32 = 0xFFFFFFFF;
        \\
        \\/// Country political fill color palette (ARGB) from MapLibre's Natural Earth globe style.
        \\pub const country_palette = [6]u32{
        \\    0xFFD6C7FF,
        \\    0xFFEBCA8A,
        \\    0xFFC1E599,
        \\    0xFFE7E58F,
        \\    0xFF98DDA1,
        \\    0xFFEAB38F,
        \\};
        \\
        \\/// Compact country vertex: centi-degrees longitude/latitude and palette index.
        \\pub const CountryVertex = struct {
        \\    lon_cd: i16,
        \\    lat_cd: i16,
        \\    color_idx: u8,
        \\};
        \\
        \\pub const MeshBatch = struct {
        \\    vert_start: u32,
        \\    vert_count: u16,
        \\    idx_start: u32,
        \\    idx_count: u32,
        \\};
        \\
        \\pub const LineSpan = struct {
        \\    start: u32,
        \\    len: u16,
        \\};
        \\
        \\pub const CountryLabel = struct {
        \\    name: []const u8,
        \\    lat: f32,
        \\    lon: f32,
        \\    rank: u8,
        \\};
        \\
        \\
    );

    try writeDatasetArrays(arena, &out, "", lod_110m);
    try writeDatasetArrays(arena, &out, "_50m", lod_50m);

    return out.toOwnedSlice(arena);
}

fn internVert(
    arena: std.mem.Allocator,
    vert_map: *std.AutoHashMapUnmanaged(VertKey, u16),
    verts: *std.ArrayList(VertKey),
    batch_vert_start: u32,
    lon: f64,
    lat: f64,
    color_idx: u8,
) !u16 {
    const qp = quantPt(lon, lat);
    const key = VertKey{ .lon_cd = qp[0], .lat_cd = qp[1], .color_idx = color_idx };
    if (vert_map.get(key)) |idx| return idx;
    const idx: u16 = @intCast(verts.items.len - batch_vert_start);
    try verts.append(arena, key);
    try vert_map.put(arena, key, idx);
    return idx;
}

fn processPolygon(
    arena: std.mem.Allocator,
    rings_json: []const std.json.Value,
    feat_idx: u32,
    color_idx: u8,
    country_rings: *std.ArrayList(CountryRing),
    edge_owners: anytype,
) !void {
    if (rings_json.len == 0) return;
    const outer_json = rings_json[0].array.items;

    var outer: std.ArrayList(Point2f) = .empty;
    var q_ring: std.ArrayList(QuantPt) = .empty;

    for (outer_json) |pt_val| {
        const pair = pt_val.array.items;
        if (pair.len < 2) continue;
        const lon = jsonNumber(pair[0]) orelse continue;
        const lat = jsonNumber(pair[1]) orelse continue;
        try outer.append(arena, .{ lon, lat });
        const qp = quantPt(lon, lat);
        if (q_ring.items.len == 0 or q_ring.items[q_ring.items.len - 1][0] != qp[0] or q_ring.items[q_ring.items.len - 1][1] != qp[1]) {
            try q_ring.append(arena, qp);
        }
    }

    if (q_ring.items.len >= 2 and (q_ring.items[0][0] != q_ring.items[q_ring.items.len - 1][0] or q_ring.items[0][1] != q_ring.items[q_ring.items.len - 1][1])) {
        try q_ring.append(arena, q_ring.items[0]);
    }
    if (q_ring.items.len < 4) return;

    for (0..q_ring.items.len - 1) |i| {
        const key = EdgeKey.make(q_ring.items[i], q_ring.items[i + 1]);
        const gop = try edge_owners.getOrPut(arena, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .first_feat = feat_idx, .shared = false };
        } else if (gop.value_ptr.first_feat != feat_idx) {
            gop.value_ptr.shared = true;
        }
    }

    try country_rings.append(arena, .{
        .feat_idx = feat_idx,
        .color_idx = color_idx,
        .outer = outer.items,
        .q_ring = q_ring.items,
    });
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3 and args.len != 4) {
        std.debug.print("usage: mkmap <ne_110m.geojson> [ne_50m.geojson] <map_data.zig>\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    const geojson_110m = try cwd.readFileAlloc(init.io, args[1], arena, .limited(32 << 20));
    const geojson_50m = if (args.len == 4)
        try cwd.readFileAlloc(init.io, args[2], arena, .limited(32 << 20))
    else
        geojson_110m;
    const out_path = args[args.len - 1];
    const zig_src = try generateTwoLod(arena, geojson_110m, geojson_50m);

    const out_file = try cwd.createFile(init.io, out_path, .{});
    defer out_file.close(init.io);
    try out_file.writeStreamingAll(init.io, zig_src);
}

test "mkmap triangulates GeoJSON polygon and classifies shared borders vs coastlines" {
    const sample_geojson =
        \\{
        \\  "type": "FeatureCollection",
        \\  "features": [
        \\    {
        \\      "type": "Feature",
        \\      "properties": { "ADM0_A3": "FRA", "NAME": "France", "LABEL_X": 2.55, "LABEL_Y": 46.70, "LABELRANK": 2 },
        \\      "geometry": {
        \\        "type": "Polygon",
        \\        "coordinates": [[[0.0, 42.0], [5.0, 42.0], [5.0, 48.0], [0.0, 48.0], [0.0, 42.0]]]
        \\      }
        \\    },
        \\    {
        \\      "type": "Feature",
        \\      "properties": { "ADM0_A3": "ESP", "NAME": "Spain", "LABEL_X": -3.46, "LABEL_Y": 40.09, "LABELRANK": 2 },
        \\      "geometry": {
        \\        "type": "Polygon",
        \\        "coordinates": [[[0.0, 36.0], [5.0, 36.0], [5.0, 42.0], [0.0, 42.0], [0.0, 36.0]]]
        \\      }
        \\    }
        \\  ]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try generate(arena.allocator(), sample_geojson);
    try std.testing.expect(std.mem.indexOf(u8, code, "pub const country_vertices =") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "pub const border_spans = [1]LineSpan") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, ".name = \"France\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, ".name = \"Spain\"") != null);
}

test "neighbouring countries never share a colour; others keep MapLibre's" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // ARM and ATG (both MapLibre's first colour) share an edge; MNE (also
    // the first) borders neither.
    const geojson =
        \\{ "type": "FeatureCollection", "features": [
        \\  { "type": "Feature", "properties": { "ADM0_A3": "ARM" }, "geometry": { "type": "Polygon",
        \\    "coordinates": [[[0, 0], [5, 0], [5, 5], [0, 5], [0, 0]]] } },
        \\  { "type": "Feature", "properties": { "ADM0_A3": "ATG" }, "geometry": { "type": "MultiPolygon",
        \\    "coordinates": [[[[5, 0], [10, 0], [10, 5], [5, 5], [5, 0]]]] } },
        \\  { "type": "Feature", "properties": { "ADM0_A3": "MNE" }, "geometry": { "type": "Polygon",
        \\    "coordinates": [[[20, 20], [25, 20], [25, 25], [20, 25], [20, 20]]] } }
        \\] }
    ;
    try std.testing.expectEqual(getCountryColorIdx("ARM"), getCountryColorIdx("ATG"));
    const colours = try countryColors(arena, &.{geojson});
    try std.testing.expect(colours.get("ARM").? != colours.get("ATG").?);
    try std.testing.expectEqual(getCountryColorIdx("MNE"), colours.get("MNE").?);
}
