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

pub fn drawConnectionLines(points: []const data.Point, nd: *const data.NucleusData, cf: *const ui.ClusterFilter) void {
    var att_pos: [constants.NUM_ATTRACTORS]rl.Vector2 = undefined;
    var att_found: [constants.NUM_ATTRACTORS]bool = .{false} ** constants.NUM_ATTRACTORS;

    for (points) |p| {
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

    for (points) |p| {
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

pub fn drawGlow(points: []const data.Point, max_delta: f32, cf: *const ui.ClusterFilter) void {
    for (points) |p| {
        if (hidden(cf, p.cluster)) continue;
        if (p.delta <= 0 or p.fade < 0.05) continue;
        const intensity = p.delta / @max(max_delta, 1.0);
        const radius = 0.3 + intensity * 0.8;
        const alpha: u8 = @intFromFloat(@min(60.0, intensity * 60.0 * p.fade));
        const cc = constants.PALETTE[p.cluster % constants.NUM_CLUSTERS];
        rl.drawCircleV(rl.vec2(p.x, p.y), radius, rl.color(cc.r, cc.g, cc.b, alpha));
    }
}

pub fn drawDots(points: []const data.Point, max_total: f32, max_delta: f32, cf: *const ui.ClusterFilter) void {
    for (points) |p| {
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

pub fn drawAttractorRings(points: []const data.Point, cf: *const ui.ClusterFilter) void {
    for (points) |p| {
        if (!p.is_attractor) continue;
        if (hidden(cf, p.cluster)) continue;
        const cc = constants.PALETTE[p.cluster % constants.NUM_CLUSTERS];
        rl.drawCircleLinesV(rl.vec2(p.x, p.y), 0.5, rl.colorFade(cc, 0.6));
        rl.drawCircleLinesV(rl.vec2(p.x, p.y), 0.3, rl.colorFade(cc, 0.3));
    }
}

pub fn drawLabels(points: []const data.Point, nd: *const data.NucleusData, cam: rl.Camera2D, font: rl.Font, cf: *const ui.ClusterFilter) void {
    for (points) |p| {
        if (hidden(cf, p.cluster)) continue;
        if (p.fade < 0.1) continue;
        const word = nd.displayWord(p.name_idx);

        const is_moving_fast = p.speed > 1.0;
        const is_labeled = p.is_attractor or is_moving_fast or (cam.zoom > 40 and p.delta > 5) or (cam.zoom > 80);
        if (!is_labeled) continue;

        const font_size: f32 = if (p.is_attractor) 14.0 else if (is_moving_fast) 11.0 else 10.0;
        const screen_pos = rl.getWorldToScreen2D(rl.vec2(p.x, p.y), cam);

        const alpha: u8 = @intFromFloat(@min(255.0, 255.0 * p.fade));
        const col = if (p.is_attractor)
            rl.colorAlpha(constants.HUD_COLOR, alpha)
        else if (is_moving_fast) blk: {
            // White-hot to cool blue based on velocity
            const v = std.math.clamp((p.speed - 1.0) / 8.0, 0.0, 1.0); // 1..9 u/s mapped to 0..1
            const r: u8 = @intFromFloat(80.0 + 175.0 * v); // blue(80) -> white(255)
            const g: u8 = @intFromFloat(120.0 + 135.0 * v); // blue(120) -> white(255)
            const b: u8 = 255;
            const va: u8 = @intFromFloat(@min(255.0, (100.0 + 155.0 * v) * p.fade)); // alpha ramps with speed
            break :blk rl.color(r, g, b, va);
        } else
            rl.colorAlpha(constants.LABEL_COLOR, alpha);

        var buf: [128]u8 = undefined;
        const len = @min(word.len, 127);
        @memcpy(buf[0..len], word[0..len]);
        buf[len] = 0;
        const text: [*:0]const u8 = @ptrCast(&buf);

        rl.drawTextEx(font, text, rl.vec2(screen_pos.x + 8, screen_pos.y - font_size / 2), font_size, 1.0, col);
    }
}

pub fn drawUncertaintyArrows(points: []const data.Point, cf: *const ui.ClusterFilter) void {
    for (points) |p| {
        if (hidden(cf, p.cluster)) continue;
        if (p.fade < 0.1) continue;
        if (@abs(p.u_shift) < 0.001) continue;
        const dir: f32 = if (p.u_shift > 0) -1.0 else 1.0;
        const len = @min(@abs(p.u_shift) * 3.0, 0.4);
        const start = rl.vec2(p.x, p.y);
        const end = rl.vec2(p.x, p.y + dir * len);
        const alpha: u8 = @intFromFloat(@min(180.0, 180.0 * p.fade));
        const col = if (p.u_shift > 0)
            rl.color(255, 100, 100, alpha)
        else
            rl.color(100, 255, 100, alpha);
        rl.drawLineV(start, end, col);
        const hs: f32 = 0.06;
        rl.drawTriangle(
            rl.vec2(end.x, end.y + dir * hs),
            rl.vec2(end.x - hs * 0.5, end.y),
            rl.vec2(end.x + hs * 0.5, end.y),
            col,
        );
    }
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

pub fn drawSearchHighlights(points: []const data.Point, nd: *const data.NucleusData, query: []const u8) void {
    if (query.len == 0) return;
    for (points) |p| {
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
