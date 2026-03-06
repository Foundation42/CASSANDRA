const std = @import("std");
const rl = @import("rl.zig");
const data = @import("data.zig");
const constants = @import("constants.zig");
const ui = @import("ui.zig");
const navmesh = @import("navmesh.zig");

fn hidden(cf: *const ui.ClusterFilter, cluster: u8) bool {
    return !cf.isVisible(cluster);
}

pub fn drawGrid(cam: rl.Camera2D, sw: c_int, sh: c_int) void {
    const top_left = rl.getScreenToWorld2D(rl.vec2(0, 0), cam);
    const bot_right = rl.getScreenToWorld2D(rl.vec2(
        @floatFromInt(sw),
        @floatFromInt(sh),
    ), cam);

    const grid_step: f32 = 5.0;
    var x = @floor(top_left.x / grid_step) * grid_step;
    while (x <= bot_right.x) : (x += grid_step) {
        rl.drawLineV(rl.vec2(x, top_left.y), rl.vec2(x, bot_right.y), constants.GRID_COLOR);
    }
    var y = @floor(top_left.y / grid_step) * grid_step;
    while (y <= bot_right.y) : (y += grid_step) {
        rl.drawLineV(rl.vec2(top_left.x, y), rl.vec2(bot_right.x, y), constants.GRID_COLOR);
    }
}

pub fn drawConnectionLines(points: []const data.Point, cf: *const ui.ClusterFilter, visible: []const u16) void {
    // Build attractor index → position from the displayed points themselves.
    // Scan all points (not just visible) to preserve attractor ordering that
    // matches nearest_attractor indices baked into each point.
    var att_pos: [constants.NUM_ATTRACTORS]rl.Vector2 = undefined;
    var att_found: [constants.NUM_ATTRACTORS]bool = .{false} ** constants.NUM_ATTRACTORS;
    var att_count: usize = 0;

    for (points) |p| {
        if (p.is_attractor and att_count < constants.NUM_ATTRACTORS) {
            att_pos[att_count] = rl.vec2(p.x, p.y);
            att_found[att_count] = true;
            att_count += 1;
        }
    }

    for (visible) |idx| {
        const p = points[idx];
        if (hidden(cf, p.cluster)) continue;
        if (p.is_attractor) continue;
        if (p.fade < 0.1) continue;
        const ai = p.nearest_attractor;
        if (ai < constants.NUM_ATTRACTORS and ai < att_count and att_found[ai]) {
            const alpha: u8 = @intFromFloat(@min(255.0, @max(0.0, 30.0 * p.fade)));
            rl.drawLineV(rl.vec2(p.x, p.y), att_pos[ai], rl.color(60, 60, 80, alpha));
        }
    }
}

pub fn drawGlow(points: []const data.Point, max_delta: f32, cf: *const ui.ClusterFilter, visible: []const u16) void {
    for (visible) |idx| {
        const p = points[idx];
        if (hidden(cf, p.cluster)) continue;
        if (p.delta <= 0 or p.fade < 0.05) continue;
        const intensity = p.delta / @max(max_delta, 1.0);
        const radius = 0.3 + intensity * 0.8;
        const alpha: u8 = @intFromFloat(@min(60.0, intensity * 60.0 * p.fade));
        const cc = constants.PALETTE[p.cluster % constants.NUM_CLUSTERS];
        rl.drawCircleV(rl.vec2(p.x, p.y), radius, rl.color(cc.r, cc.g, cc.b, alpha));
    }
}

pub fn drawDots(points: []const data.Point, max_total: f32, max_delta: f32, cf: *const ui.ClusterFilter, visible: []const u16) void {
    for (visible) |idx| {
        const p = points[idx];
        if (hidden(cf, p.cluster)) continue;
        if (p.fade < 0.05) continue;
        const base_r: f32 = 0.04 + (p.total / @max(max_total, 1.0)) * 0.15;
        const delta_boost: f32 = if (max_delta > 0) (p.delta / max_delta) * 0.08 else 0;
        const speed_boost: f32 = @min(p.speed * 0.02, 0.1);
        const radius = (base_r + delta_boost + speed_boost) * p.fade;

        const cc = constants.PALETTE[p.cluster % constants.NUM_CLUSTERS];
        const alpha: u8 = @intFromFloat(@min(255.0, @max(30.0, 255.0 * p.fade)));
        rl.drawCircleV(rl.vec2(p.x, p.y), radius, rl.color(cc.r, cc.g, cc.b, alpha));
    }
}

pub fn drawAttractorRings(points: []const data.Point, cf: *const ui.ClusterFilter, visible: []const u16) void {
    for (visible) |idx| {
        const p = points[idx];
        if (!p.is_attractor) continue;
        if (hidden(cf, p.cluster)) continue;
        const cc = constants.PALETTE[p.cluster % constants.NUM_CLUSTERS];
        rl.drawCircleLinesV(rl.vec2(p.x, p.y), 0.5, rl.colorFade(cc, 0.6));
        rl.drawCircleLinesV(rl.vec2(p.x, p.y), 0.3, rl.colorFade(cc, 0.3));
    }
}

fn labelImportance(p: data.Point, max_delta: f32, zoom: f32) f32 {
    if (p.is_attractor) return 10.0; // always above any budget cut
    const activity: f32 = if (max_delta > 0) p.delta / max_delta else 0;
    const spd = std.math.clamp(p.speed / 4.0, 0.0, 1.0);
    const zoom_reveal = std.math.clamp((zoom - 40.0) / 80.0, 0.0, 1.0);
    // Blend activity and speed rather than pure max — prevents single-frame spikes
    // from popping in labels. zoom_reveal still uses max so zooming in always reveals.
    const motion = activity * 0.7 + spd * 0.3;
    return @max(motion, zoom_reveal) * p.fade;
}

/// Label budget scales with zoom: 12 when fully zoomed out, up to MAX_LABELS when zoomed in.
fn labelBudget(zoom: f32) usize {
    const t = std.math.clamp((zoom - 10.0) / 60.0, 0.0, 1.0); // 0 at zoom<=10, 1 at zoom>=70
    const t2 = std.math.clamp((zoom - 70.0) / 200.0, 0.0, 1.0); // extra budget for deep zoom
    return @intFromFloat(12.0 + 38.0 * t + @as(f32, MAX_LABELS - 50) * t2);
}

/// Importance threshold: stricter when zoomed out (0.4), relaxes to 0 at deep zoom (all labels visible).
fn labelThreshold(zoom: f32) f32 {
    const t = std.math.clamp((zoom - 10.0) / 100.0, 0.0, 1.0);
    return 0.4 - 0.4 * t; // 0.4 → 0.0
}

const LabelSlot = struct { idx: u16, importance: f32 };
const MAX_LABELS = 200;

pub fn drawLabels(points: []const data.Point, nd: *const data.NucleusData, cam: rl.Camera2D, font: rl.Font, cf: *const ui.ClusterFilter, max_delta: f32, visible: []const u16) void {
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    const sh: f32 = @floatFromInt(rl.getScreenHeight());
    const margin: f32 = 50; // small margin so labels near edges still appear

    // --- Pass 1: collect top-K non-attractor labels by importance (viewport only) ---
    const budget = labelBudget(cam.zoom);
    const imp_threshold = labelThreshold(cam.zoom);

    var slots: [MAX_LABELS]LabelSlot = undefined;
    var n_slots: usize = 0;
    var min_imp: f32 = 0;
    var min_idx: usize = 0;

    for (visible) |vi| {
        const p = points[vi];
        if (hidden(cf, p.cluster)) continue;
        if (p.fade < 0.1) continue;
        if (p.is_attractor) continue;

        // Viewport cull: skip points not on screen
        const sp = rl.getWorldToScreen2D(rl.vec2(p.x, p.y), cam);
        if (sp.x < -margin or sp.x > sw + margin or sp.y < -margin or sp.y > sh + margin) continue;

        const imp = labelImportance(p, max_delta, cam.zoom);
        if (imp < imp_threshold) continue;

        if (n_slots < budget) {
            slots[n_slots] = .{ .idx = vi, .importance = imp };
            n_slots += 1;
            // Recompute min when buffer fills
            if (n_slots == budget) {
                min_imp = slots[0].importance;
                min_idx = 0;
                for (0..n_slots) |j| {
                    if (slots[j].importance < min_imp) {
                        min_imp = slots[j].importance;
                        min_idx = j;
                    }
                }
            }
        } else if (imp > min_imp) {
            slots[min_idx] = .{ .idx = vi, .importance = imp };
            // Find new min
            min_imp = slots[0].importance;
            min_idx = 0;
            for (0..budget) |j| {
                if (slots[j].importance < min_imp) {
                    min_imp = slots[j].importance;
                    min_idx = j;
                }
            }
        }
    }

    // Find the importance threshold (lowest in the budget) for alpha fade
    const threshold: f32 = if (n_slots == budget) min_imp else imp_threshold;

    // --- Pass 2: draw attractor labels (always) + budgeted labels ---
    for (visible) |vi| {
        const p = points[vi];
        if (!p.is_attractor) continue;
        if (hidden(cf, p.cluster)) continue;
        if (p.fade < 0.1) continue;
        drawOneLabel(p, nd, cam, font, 1.0);
    }

    for (slots[0..n_slots]) |slot| {
        const p = points[slot.idx];
        // Fade: full alpha for top labels, fade near the cutoff
        const above = slot.importance - threshold;
        const range = if (n_slots == MAX_LABELS) @max(slots[0].importance, threshold + 0.01) - threshold else 0.5;
        const alpha = std.math.clamp(above / (range * 0.3), 0.0, 1.0) * p.fade;
        if (alpha < 0.02) continue;
        drawOneLabel(p, nd, cam, font, alpha);
    }
}

fn drawOneLabel(p: data.Point, nd: *const data.NucleusData, cam: rl.Camera2D, font: rl.Font, label_alpha: f32) void {
    const word = nd.displayWord(p.name_idx);
    const is_moving_fast = p.speed > 1.0;
    const base_size: f32 = if (p.is_attractor) 15.0 else if (is_moving_fast) 11.0 else 10.0;
    // Scale with zoom: subtle boost so labels grow when zoomed in
    const zoom_scale = 1.0 + std.math.clamp((cam.zoom - 1.0) * 0.15, 0.0, 1.5);
    const font_size: f32 = base_size * zoom_scale;
    const screen_pos = rl.getWorldToScreen2D(rl.vec2(p.x, p.y), cam);

    const alpha: u8 = @intFromFloat(@min(255.0, 255.0 * label_alpha));
    const cc = constants.PALETTE[p.cluster % constants.NUM_CLUSTERS];
    const col = if (p.is_attractor)
        rl.colorAlpha(cc, alpha)
    else if (is_moving_fast) blk: {
        // Blend from muted cluster color toward bright cluster color with speed
        const v = std.math.clamp((p.speed - 1.0) / 8.0, 0.0, 1.0);
        const r: u8 = @intFromFloat(@as(f32, @floatFromInt(cc.r)) * (0.4 + 0.6 * v));
        const g: u8 = @intFromFloat(@as(f32, @floatFromInt(cc.g)) * (0.4 + 0.6 * v));
        const b: u8 = @intFromFloat(@as(f32, @floatFromInt(cc.b)) * (0.4 + 0.6 * v));
        const va: u8 = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(alpha)) * (0.4 + 0.6 * v)));
        break :blk rl.color(r, g, b, va);
    } else blk: {
        // Desaturated cluster color for quiet labels
        const r: u8 = @intFromFloat((@as(f32, @floatFromInt(cc.r)) + 200.0) / 2.0);
        const g: u8 = @intFromFloat((@as(f32, @floatFromInt(cc.g)) + 200.0) / 2.0);
        const b: u8 = @intFromFloat((@as(f32, @floatFromInt(cc.b)) + 210.0) / 2.0);
        break :blk rl.color(r, g, b, alpha);
    };

    var buf: [128]u8 = undefined;
    const len = @min(word.len, 127);
    @memcpy(buf[0..len], word[0..len]);
    buf[len] = 0;
    const text: [*:0]const u8 = @ptrCast(&buf);

    const tx = @round(screen_pos.x + 8);
    const ty = @round(screen_pos.y - font_size / 2);
    const shadow_a: u8 = @intFromFloat(@min(180.0, 180.0 * label_alpha));
    rl.drawTextEx(font, text, rl.vec2(tx + 1, ty + 1), font_size, 1.0, rl.color(0, 0, 0, shadow_a));
    rl.drawTextEx(font, text, rl.vec2(tx, ty), font_size, 1.0, col);
}



pub fn drawNavmesh(
    points: []const data.Point,
    nav_paths: []const navmesh.NavPath,
    cf: *const ui.ClusterFilter,
    focus: ?u16,
) void {
    for (nav_paths) |path| {
        if (path.len < 2) continue;
        if (!cf.isVisible(path.cluster_a) or !cf.isVisible(path.cluster_b)) continue;

        // Must have a focused attractor to show paths
        const f = focus orelse continue;
        if (path.nodes[0] != f and path.nodes[path.len - 1] != f) continue;

        // Fade by path length: short paths are bold, long ones are subtle
        const hops = path.len - 1;
        // 1 hop → 1.0, 2 → 0.8, 3 → 0.6, 4 → 0.4, 5+ → 0.25
        const prominence: f32 = if (hops <= 1) 1.0 else if (hops <= 4) 1.0 - @as(f32, @floatFromInt(hops - 1)) * 0.2 else 0.25;
        const line_alpha: u8 = @intFromFloat(40.0 + 160.0 * prominence);
        const dot_alpha: u8 = @intFromFloat(60.0 + 180.0 * prominence);
        const thickness: f32 = 0.04 + 0.12 * prominence;
        const dot_radius: f32 = 0.04 + 0.10 * prominence;

        // Blend color from the two endpoint clusters
        const ca = constants.PALETTE[path.cluster_a % constants.NUM_CLUSTERS];
        const cb = constants.PALETTE[path.cluster_b % constants.NUM_CLUSTERS];
        const line_col = rl.color(
            @intCast((@as(u16, ca.r) + @as(u16, cb.r)) / 2),
            @intCast((@as(u16, ca.g) + @as(u16, cb.g)) / 2),
            @intCast((@as(u16, ca.b) + @as(u16, cb.b)) / 2),
            line_alpha,
        );
        const dot_col = rl.color(
            @intCast((@as(u16, ca.r) + @as(u16, cb.r)) / 2),
            @intCast((@as(u16, ca.g) + @as(u16, cb.g)) / 2),
            @intCast((@as(u16, ca.b) + @as(u16, cb.b)) / 2),
            dot_alpha,
        );

        // Draw segments
        var prev_pos: ?rl.Vector2 = null;
        for (0..path.len) |pi| {
            const name_idx = path.nodes[pi];
            const pos = findPointPos(points, name_idx) orelse continue;

            if (prev_pos) |pp| {
                rl.drawLineEx(pp, pos, thickness, line_col);
            }
            prev_pos = pos;

            // Draw waypoint dot for intermediate nodes
            if (pi > 0 and pi < path.len - 1) {
                rl.drawCircleV(pos, dot_radius, dot_col);
            }
        }
    }

    // Collect waypoint name_idxs (non-attractor intermediates) for labeling
    nav_waypoint_count = 0;
    for (nav_paths) |path| {
        if (path.len < 2) continue;
        if (!cf.isVisible(path.cluster_a) or !cf.isVisible(path.cluster_b)) continue;
        const f = focus orelse continue;
        if (path.nodes[0] != f and path.nodes[path.len - 1] != f) continue;

        for (0..path.len) |pi| {
            if (pi == 0 or pi == path.len - 1) continue; // skip attractor endpoints
            if (nav_waypoint_count >= MAX_WAYPOINTS) break;
            const ni = path.nodes[pi];
            // Deduplicate
            var dup = false;
            for (nav_waypoints[0..nav_waypoint_count]) |existing| {
                if (existing == ni) {
                    dup = true;
                    break;
                }
            }
            if (!dup) {
                nav_waypoints[nav_waypoint_count] = ni;
                nav_waypoint_count += 1;
            }
        }
    }
}

const MAX_WAYPOINTS = 128;
var nav_waypoints: [MAX_WAYPOINTS]u16 = undefined;
var nav_waypoint_count: usize = 0;

pub fn drawNavmeshLabels(points: []const data.Point, nd: *const data.NucleusData, cam: rl.Camera2D, font: rl.Font) void {
    for (nav_waypoints[0..nav_waypoint_count]) |ni| {
        // Find point
        for (points) |p| {
            if (p.name_idx == ni) {
                drawOneLabel(p, nd, cam, font, 0.9);
                break;
            }
        }
    }
}

fn findPointPos(points: []const data.Point, name_idx: u16) ?rl.Vector2 {
    // Linear scan — paths are short and this runs ~45 times per frame
    for (points) |p| {
        if (p.name_idx == name_idx) return rl.vec2(p.x, p.y);
    }
    return null;
}

pub fn drawVignette(sw: c_int, sh: c_int) void {
    _ = sw;
    _ = sh;
}

pub fn drawHighlight(points: []const data.Point, idx: u16) void {
    if (idx >= points.len) return;
    const p = points[idx];
    rl.drawCircleLinesV(rl.vec2(p.x, p.y), 0.4, constants.HIGHLIGHT_COLOR);
    rl.drawCircleLinesV(rl.vec2(p.x, p.y), 0.45, rl.colorAlpha(constants.HIGHLIGHT_COLOR, 120));
}

pub fn drawSearchHighlights(points: []const data.Point, nd: *const data.NucleusData, query: []const u8, visible: []const u16) void {
    if (query.len == 0) return;
    for (visible) |idx| {
        const p = points[idx];
        const word = nd.displayWord(p.name_idx);
        if (containsInsensitive(word, query)) {
            rl.drawCircleLinesV(rl.vec2(p.x, p.y), 0.35, constants.HIGHLIGHT_COLOR);
        }
    }
}

fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            if (toLower(haystack[i + j]) != toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn toLower(ch: u8) u8 {
    if (ch >= 'A' and ch <= 'Z') return ch + 32;
    return ch;
}
