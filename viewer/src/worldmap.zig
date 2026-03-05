const std = @import("std");
const rl = @import("rl.zig");

const BORDER_COLOR = rl.color(40, 60, 90, 160);
const SELECTED_BORDER_COLOR = rl.color(80, 140, 200, 220);
const FILL_COLOR = rl.color(200, 30, 30, 120);
const LABEL_COLOR = rl.color(40, 50, 70, 60);
const LABEL_ZOOM_MIN: f32 = 0.8;
const LABEL_ZOOM_MAX: f32 = 6.0;

const Polygon = struct {
    points: [][2]f32,
    tris: []u16, // precomputed triangle indices (ear clipping), len is multiple of 3
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,
};

const Region = struct {
    name: []const u8,
    iso: [2]u8,
    centroid: [2]f32,
    polygons: []Polygon,
};

pub const WorldMap = struct {
    regions: []Region,
    buf: []align(4) u8,
    selected: ?usize = null, // index into regions

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !WorldMap {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            std.debug.print("worldmap: cannot open {s}: {}\n", .{ path, err });
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        const buf = try allocator.alignedAlloc(u8, 4, stat.size);
        const n = try file.readAll(buf);
        if (n != stat.size) return error.ShortRead;

        var off: usize = 0;

        const num_regions = readU32(buf, &off);
        const regions = try allocator.alloc(Region, num_regions);

        for (regions) |*region| {
            const name_len = readU16(buf, &off);
            const name = buf[off..][0..name_len];
            off += name_len;

            const iso: [2]u8 = .{ buf[off], buf[off + 1] };
            off += 2;

            const cx = readF32(buf, &off);
            const cy = readF32(buf, &off);

            const num_polys = readU16(buf, &off);
            const polygons = try allocator.alloc(Polygon, num_polys);

            for (polygons) |*poly| {
                const num_pts = readU32(buf, &off);
                const points = try allocator.alloc([2]f32, num_pts);

                var min_x: f32 = std.math.floatMax(f32);
                var min_y: f32 = std.math.floatMax(f32);
                var max_x: f32 = -std.math.floatMax(f32);
                var max_y: f32 = -std.math.floatMax(f32);

                for (points) |*pt| {
                    const x = readF32(buf, &off);
                    const y = readF32(buf, &off);
                    pt.* = .{ x, y };
                    min_x = @min(min_x, x);
                    min_y = @min(min_y, y);
                    max_x = @max(max_x, x);
                    max_y = @max(max_y, y);
                }

                poly.* = .{
                    .points = points,
                    .tris = earClip(points, allocator) catch &.{},
                    .min_x = min_x,
                    .min_y = min_y,
                    .max_x = max_x,
                    .max_y = max_y,
                };
            }

            region.* = .{
                .name = name,
                .iso = iso,
                .centroid = .{ cx, cy },
                .polygons = polygons,
            };
        }

        var total_tris: usize = 0;
        for (regions) |r| {
            for (r.polygons) |p| total_tris += p.tris.len / 3;
        }
        std.debug.print("worldmap: loaded {} regions, {} triangles\n", .{ num_regions, total_tris });
        return .{ .regions = regions, .buf = buf };
    }

    /// Handle shift-click: hit-test regions and toggle selection.
    pub fn handleInput(self: *WorldMap, cam: rl.Camera2D) void {
        if (rl.isMouseButtonPressed(rl.MOUSE_BUTTON_LEFT) and rl.isKeyDown(rl.KEY_LEFT_SHIFT)) {
            const mouse = rl.getScreenToWorld2D(rl.getMousePosition(), cam);
            const hit = self.hitTest(mouse.x, mouse.y);
            if (hit) |idx| {
                if (self.selected) |cur| {
                    self.selected = if (cur == idx) null else idx;
                } else {
                    self.selected = idx;
                }
                if (self.selected) |sel| {
                    std.debug.print("worldmap: selected {s}\n", .{self.regions[sel].name});
                }
            } else {
                self.selected = null;
            }
        }
    }

    pub fn draw(self: *const WorldMap, cam: rl.Camera2D, sw: c_int, sh: c_int) void {
        const tl = rl.getScreenToWorld2D(rl.vec2(0, 0), cam);
        const br = rl.getScreenToWorld2D(rl.vec2(@floatFromInt(sw), @floatFromInt(sh)), cam);

        // Draw fills for selected region first (behind all borders)
        if (self.selected) |sel| {
            const region = self.regions[sel];
            for (region.polygons) |poly| {
                if (poly.max_x < tl.x or poly.min_x > br.x) continue;
                if (poly.max_y < tl.y or poly.min_y > br.y) continue;
                fillPolygon(poly.points, poly.tris, FILL_COLOR);
            }
        }

        // Draw all borders
        for (self.regions, 0..) |region, ri| {
            const is_selected = if (self.selected) |sel| ri == sel else false;
            const col = if (is_selected) SELECTED_BORDER_COLOR else BORDER_COLOR;

            for (region.polygons) |poly| {
                if (poly.max_x < tl.x or poly.min_x > br.x) continue;
                if (poly.max_y < tl.y or poly.min_y > br.y) continue;

                const pts = poly.points;
                if (pts.len < 2) continue;

                for (0..pts.len) |i| {
                    const j = (i + 1) % pts.len;
                    rl.drawLineV(
                        rl.vec2(pts[i][0], pts[i][1]),
                        rl.vec2(pts[j][0], pts[j][1]),
                        col,
                    );
                }
            }
        }
    }

    pub fn drawLabels(self: *const WorldMap, cam: rl.Camera2D, font: rl.Font) void {
        const zoom = cam.zoom;
        if (zoom < LABEL_ZOOM_MIN or zoom > LABEL_ZOOM_MAX) return;

        const alpha_f = blk: {
            if (zoom < LABEL_ZOOM_MIN + 0.3) {
                break :blk (zoom - LABEL_ZOOM_MIN) / 0.3;
            }
            if (zoom > LABEL_ZOOM_MAX - 1.0) {
                break :blk (LABEL_ZOOM_MAX - zoom) / 1.0;
            }
            break :blk 1.0;
        };

        const base_a: f32 = @floatFromInt(LABEL_COLOR.a);
        const a: u8 = @intFromFloat(@max(0, @min(255, base_a * alpha_f)));
        const col = rl.color(LABEL_COLOR.r, LABEL_COLOR.g, LABEL_COLOR.b, a);

        const font_size: f32 = 9.0 / zoom;

        for (self.regions) |region| {
            if (region.name.len == 0) continue;

            var name_buf: [64]u8 = undefined;
            const len = @min(region.name.len, 63);
            @memcpy(name_buf[0..len], region.name[0..len]);
            name_buf[len] = 0;
            const name_z: [*:0]const u8 = @ptrCast(&name_buf);

            const pos = rl.vec2(region.centroid[0], region.centroid[1]);
            rl.drawTextEx(font, name_z, pos, font_size, font_size * 0.1, col);
        }
    }

    /// Ray-casting point-in-polygon, returns region index.
    fn hitTest(self: *const WorldMap, wx: f32, wy: f32) ?usize {
        for (self.regions, 0..) |region, ri| {
            for (region.polygons) |poly| {
                // Quick bbox check
                if (wx < poly.min_x or wx > poly.max_x) continue;
                if (wy < poly.min_y or wy > poly.max_y) continue;

                if (pointInPolygon(poly.points, wx, wy)) return ri;
            }
        }
        return null;
    }
};

/// Ray-casting algorithm for point-in-polygon test.
fn pointInPolygon(pts: [][2]f32, px: f32, py: f32) bool {
    var inside = false;
    var j: usize = pts.len - 1;
    for (0..pts.len) |i| {
        const yi = pts[i][1];
        const yj = pts[j][1];
        if ((yi > py) != (yj > py)) {
            const xi = pts[i][0];
            const xj = pts[j][0];
            const intersect_x = xi + (py - yi) / (yj - yi) * (xj - xi);
            if (px < intersect_x) inside = !inside;
        }
        j = i;
    }
    return inside;
}

/// Draw precomputed triangles for a polygon.
fn fillPolygon(pts: [][2]f32, tris: []const u16, col: rl.Color) void {
    var i: usize = 0;
    while (i + 2 < tris.len) : (i += 3) {
        const a = rl.vec2(pts[tris[i]][0], pts[tris[i]][1]);
        const b = rl.vec2(pts[tris[i + 1]][0], pts[tris[i + 1]][1]);
        const c = rl.vec2(pts[tris[i + 2]][0], pts[tris[i + 2]][1]);
        rl.drawTriangle(a, b, c, col);
        rl.drawTriangle(a, c, b, col);
    }
}

/// Ear-clipping triangulation. Returns index buffer (length multiple of 3).
fn earClip(raw_pts: [][2]f32, allocator: std.mem.Allocator) ![]u16 {
    // GeoJSON polygons are closed (first == last), strip the duplicate
    const pts: [][2]f32 = if (raw_pts.len > 1 and
        raw_pts[0][0] == raw_pts[raw_pts.len - 1][0] and
        raw_pts[0][1] == raw_pts[raw_pts.len - 1][1])
        raw_pts[0 .. raw_pts.len - 1]
    else
        raw_pts;
    const n = pts.len;
    if (n < 3) return &.{};

    // Determine winding: positive signed area = CCW
    var area: f32 = 0;
    for (0..n) |i| {
        const j = (i + 1) % n;
        area += pts[i][0] * pts[j][1];
        area -= pts[j][0] * pts[i][1];
    }
    const ccw = area > 0;

    // Linked list of remaining vertex indices
    const prev = try allocator.alloc(u16, n);
    defer allocator.free(prev);
    const next = try allocator.alloc(u16, n);
    defer allocator.free(next);
    for (0..n) |i| {
        prev[i] = @intCast((i + n - 1) % n);
        next[i] = @intCast((i + 1) % n);
    }

    var tris = std.ArrayList(u16).init(allocator);

    var remaining: usize = n;
    var ear: u16 = 0;
    var attempts: usize = 0;

    while (remaining > 2) {
        if (attempts >= remaining) break; // no more ears found, bail

        const p = prev[ear];
        const nx = next[ear];

        if (isEar(pts, prev, next, p, ear, nx, remaining, ccw)) {
            // Emit triangle — CCW winding for Raylib front face
            if (ccw) {
                try tris.append(p);
                try tris.append(ear);
                try tris.append(nx);
            } else {
                try tris.append(nx);
                try tris.append(ear);
                try tris.append(p);
            }

            // Remove ear from linked list
            next[p] = nx;
            prev[nx] = p;
            remaining -= 1;
            attempts = 0;
            ear = nx;
        } else {
            ear = next[ear];
            attempts += 1;
        }
    }

    return tris.toOwnedSlice();
}

fn isEar(pts: [][2]f32, _: []const u16, next: []const u16, a: u16, b: u16, c_idx: u16, remaining: usize, ccw: bool) bool {
    const ax = pts[a][0];
    const ay = pts[a][1];
    const bx = pts[b][0];
    const by = pts[b][1];
    const cx = pts[c_idx][0];
    const cy = pts[c_idx][1];

    // Cross product: must be positive (convex) for CCW winding
    const cross = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
    if (ccw and cross <= 0) return false;
    if (!ccw and cross >= 0) return false;

    // Check no other vertex inside this triangle
    var v = next[c_idx];
    var checked: usize = 0;
    while (v != a and checked < remaining) : (checked += 1) {
        if (pointInTriangle(pts[v][0], pts[v][1], ax, ay, bx, by, cx, cy)) return false;
        v = next[v];
    }
    return true;
}

fn pointInTriangle(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32) bool {
    const d1 = sign(px, py, ax, ay, bx, by);
    const d2 = sign(px, py, bx, by, cx, cy);
    const d3 = sign(px, py, cx, cy, ax, ay);
    const has_neg = (d1 < 0) or (d2 < 0) or (d3 < 0);
    const has_pos = (d1 > 0) or (d2 > 0) or (d3 > 0);
    return !(has_neg and has_pos);
}

fn sign(x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32) f32 {
    return (x1 - x3) * (y2 - y3) - (x2 - x3) * (y1 - y3);
}

fn readU32(buf: []const u8, off: *usize) u32 {
    const v = std.mem.readInt(u32, buf[off.*..][0..4], .little);
    off.* += 4;
    return v;
}

fn readU16(buf: []const u8, off: *usize) u16 {
    const v = std.mem.readInt(u16, buf[off.*..][0..2], .little);
    off.* += 2;
    return v;
}

fn readF32(buf: []const u8, off: *usize) f32 {
    const bytes = buf[off.*..][0..4];
    off.* += 4;
    return @bitCast(std.mem.readInt(u32, bytes, .little));
}
