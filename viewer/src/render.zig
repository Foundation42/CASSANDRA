const std = @import("std");
const rl = @import("rl.zig");
const data = @import("data.zig");
const constants = @import("constants.zig");
const ui = @import("ui.zig");

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

pub fn drawConnectionLines(points: []const data.Point, nd: *const data.NucleusData, cf: *const ui.ClusterFilter, visible: []const u16) void {
    var att_pos: [constants.NUM_ATTRACTORS]rl.Vector2 = undefined;
    var att_found: [constants.NUM_ATTRACTORS]bool = .{false} ** constants.NUM_ATTRACTORS;

    // Attractors: scan visible only (attractors must be visible to draw lines to them)
    for (visible) |idx| {
        const p = points[idx];
        if (p.is_attractor) {
            for (0..nd.num_attractors) |ai| {
                if (nd.attractor_names[ai] == p.name_idx) {
                    att_pos[ai] = rl.vec2(p.x, p.y);
                    att_found[ai] = true;
                    break;
                }
            }
        }
    }

    for (visible) |idx| {
        const p = points[idx];
        if (hidden(cf, p.cluster)) continue;
        if (p.is_attractor) continue;
        if (p.fade < 0.1) continue;
        const ai = p.nearest_attractor;
        if (ai < constants.NUM_ATTRACTORS and att_found[ai]) {
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

/// Label budget scales with zoom: 12 when fully zoomed out, 50 when zoomed in.
fn labelBudget(zoom: f32) usize {
    const t = std.math.clamp((zoom - 10.0) / 60.0, 0.0, 1.0); // 0 at zoom<=10, 1 at zoom>=70
    return @intFromFloat(12.0 + 38.0 * t);
}

/// Importance threshold: stricter when zoomed out (0.4) to suppress noise, relaxes when zoomed in (0.15).
fn labelThreshold(zoom: f32) f32 {
    const t = std.math.clamp((zoom - 10.0) / 60.0, 0.0, 1.0);
    return 0.4 - 0.25 * t; // 0.4 → 0.15
}

const LabelSlot = struct { idx: u16, importance: f32 };
const MAX_LABELS = 50;

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
    const font_size: f32 = if (p.is_attractor) 14.0 else if (is_moving_fast) 11.0 else 10.0;
    const screen_pos = rl.getWorldToScreen2D(rl.vec2(p.x, p.y), cam);

    const alpha: u8 = @intFromFloat(@min(255.0, 255.0 * label_alpha));
    const col = if (p.is_attractor)
        rl.colorAlpha(constants.HUD_COLOR, alpha)
    else if (is_moving_fast) blk: {
        const v = std.math.clamp((p.speed - 1.0) / 8.0, 0.0, 1.0);
        const r: u8 = @intFromFloat(80.0 + 175.0 * v);
        const g: u8 = @intFromFloat(120.0 + 135.0 * v);
        const b: u8 = 255;
        const va: u8 = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(alpha)) * (0.4 + 0.6 * v)));
        break :blk rl.color(r, g, b, va);
    } else
        rl.color(200, 200, 220, alpha);

    var buf: [128]u8 = undefined;
    const len = @min(word.len, 127);
    @memcpy(buf[0..len], word[0..len]);
    buf[len] = 0;
    const text: [*:0]const u8 = @ptrCast(&buf);

    rl.drawTextEx(font, text, rl.vec2(screen_pos.x + 8, screen_pos.y - font_size / 2), font_size, 1.0, col);
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
