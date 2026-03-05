const std = @import("std");
const rl = @import("rl.zig");
const data = @import("data.zig");
const constants = @import("constants.zig");
const timeline_mod = @import("timeline.zig");

pub const SearchState = struct {
    active: bool = false,
    buf: [64]u8 = .{0} ** 64,
    len: u8 = 0,

    pub fn query(self: *const SearchState) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn handleInput(self: *SearchState) void {
        if (!self.active) {
            if (rl.isKeyPressed(rl.KEY_SLASH)) {
                self.active = true;
                self.len = 0;
            }
            return;
        }
        if (rl.isKeyPressed(rl.KEY_ESCAPE)) {
            self.active = false;
            self.len = 0;
            return;
        }
        if (rl.isKeyPressed(rl.KEY_BACKSPACE)) {
            if (self.len > 0) self.len -= 1;
            return;
        }
        var ch = rl.getCharPressed();
        while (ch != 0) {
            if (self.len < 63 and ch >= 32 and ch < 127) {
                self.buf[self.len] = @intCast(@as(u32, @bitCast(ch)));
                self.len += 1;
            }
            ch = rl.getCharPressed();
        }
    }
};

pub const ClusterFilter = struct {
    visible: [constants.NUM_CLUSTERS]bool = .{true} ** constants.NUM_CLUSTERS,

    pub fn handleInput(self: *ClusterFilter) void {
        const keys = [_]c_int{
            rl.KEY_ONE, rl.KEY_TWO, rl.KEY_THREE, rl.KEY_FOUR,
            rl.KEY_FIVE, rl.KEY_SIX, rl.KEY_SEVEN, rl.KEY_EIGHT,
        };
        for (keys, 0..) |k, i| {
            if (rl.isKeyPressed(k)) {
                self.visible[i] = !self.visible[i];
            }
        }
    }

    pub fn isVisible(self: *const ClusterFilter, cluster: u8) bool {
        if (cluster >= constants.NUM_CLUSTERS) return true;
        return self.visible[cluster];
    }
};

pub fn drawHUD(
    font: rl.Font,
    timestamp: []const u8,
    num_visible: u32,
    num_hot: u32,
    num_keyframes: u32,
    tl: *const timeline_mod.Timeline,
    physics_active: bool,
    keyframes: []const data.Keyframe,
) void {
    _ = keyframes;
    const x: f32 = 20;
    var y: f32 = 20;
    const size: f32 = 16;

    rl.drawTextEx(font, "CASSANDRA", rl.vec2(x, y), 24, 2.0, constants.HUD_COLOR);
    y += 32;
    rl.drawTextEx(font, "WordNet Nucleus Observer", rl.vec2(x, y), 11, 1.0, constants.HUD_DIM);
    y += 20;

    var ts_buf: [32]u8 = undefined;
    const ts_len = @min(timestamp.len, 28);
    @memcpy(ts_buf[0..2], "T:");
    @memcpy(ts_buf[2 .. 2 + ts_len], timestamp[0..ts_len]);
    ts_buf[2 + ts_len] = 0;
    rl.drawTextEx(font, @ptrCast(&ts_buf), rl.vec2(x, y), size, 1.0, constants.HUD_COLOR);
    y += size + 4;

    var buf: [64]u8 = undefined;
    _ = printZ(&buf, "NUCLEI: {d}", .{num_visible});
    rl.drawTextEx(font, @ptrCast(&buf), rl.vec2(x, y), size, 1.0, constants.HUD_DIM);
    y += size + 2;

    _ = printZ(&buf, "HOT: {d}", .{num_hot});
    rl.drawTextEx(font, @ptrCast(&buf), rl.vec2(x, y), size, 1.0, constants.HUD_DIM);
    y += size + 2;

    _ = printZ(&buf, "FRAMES: {d}", .{num_keyframes});
    rl.drawTextEx(font, @ptrCast(&buf), rl.vec2(x, y), size, 1.0, constants.HUD_DIM);
    y += size + 2;

    if (tl.playing) {
        _ = printZ(&buf, "SPEED: {d:.0}x", .{tl.speed()});
        rl.drawTextEx(font, @ptrCast(&buf), rl.vec2(x, y), size, 1.0, constants.HUD_DIM);
        y += size + 2;
    } else if (tl.live) {
        rl.drawTextEx(font, "LIVE", rl.vec2(x, y), size, 1.0, constants.SCRUBBER_FG);
        y += size + 2;
    }

    if (physics_active) {
        rl.drawTextEx(font, "PHYSICS", rl.vec2(x, y), size, 1.0, constants.PHYSICS_COLOR);
    }
}

pub fn drawScrubber(tl: *timeline_mod.Timeline, font: rl.Font, sw: c_int, sh: c_int, keyframes: []const data.Keyframe) void {
    const w: f32 = @floatFromInt(sw);
    const h: f32 = @floatFromInt(sh);
    const bar_h: f32 = 40;
    const bar_y = h - bar_h;
    const margin: f32 = 80;
    const bar_w = w - margin * 2;

    rl.drawRectangle(0, @intFromFloat(bar_y), sw, @intFromFloat(bar_h), constants.SCRUBBER_BG);

    const track_y = bar_y + bar_h / 2;
    rl.drawLineEx(
        rl.vec2(margin, track_y),
        rl.vec2(margin + bar_w, track_y),
        2,
        rl.colorAlpha(constants.SCRUBBER_FG, 60),
    );

    if (tl.window > 0) {
        // --- Ruler tick marks at natural intervals ---
        const intervals = [_]f64{ 60, 300, 600, 1800, 3600, 7200, 21600, 86400 };
        // Pick the largest interval that gives at least 3 ticks
        var interval: f64 = 60;
        for (intervals) |iv| {
            if (tl.window / iv >= 3.0) {
                interval = iv;
            }
        }
        const ws = tl.windowStart();
        const first_tick = @ceil(ws / interval) * interval;
        var tick_t = first_tick;
        while (tick_t <= tl.latest_time) : (tick_t += interval) {
            if (tl.timeToFrac(tick_t)) |frac| {
                const tick_x = margin + frac * bar_w;
                rl.drawLineEx(
                    rl.vec2(tick_x, track_y - 4),
                    rl.vec2(tick_x, track_y + 4),
                    1,
                    rl.colorAlpha(constants.SCRUBBER_FG, 50),
                );
                // Draw time label for major ticks
                const secs_ago: f64 = tl.latest_time - tick_t;
                var label_buf: [16]u8 = undefined;
                if (secs_ago < 60) {
                    _ = printZ(&label_buf, "{d:.0}s", .{secs_ago});
                } else if (secs_ago < 3600) {
                    _ = printZ(&label_buf, "{d:.0}m", .{secs_ago / 60.0});
                } else {
                    _ = printZ(&label_buf, "{d:.1}h", .{secs_ago / 3600.0});
                }
                rl.drawTextEx(font, @ptrCast(&label_buf), rl.vec2(tick_x - 8, track_y + 8), 9, 1.0, rl.colorAlpha(constants.SCRUBBER_FG, 80));
            }
        }

        // --- Event dots (keyframe arrivals) ---
        for (keyframes) |kf| {
            const kf_t: f64 = @floatFromInt(kf.wall_time);
            if (tl.timeToFrac(kf_t)) |frac| {
                const dot_x = margin + frac * bar_w;
                rl.drawCircleV(rl.vec2(dot_x, track_y), 3, rl.colorAlpha(constants.SCRUBBER_FG, 120));
            }
        }

        // --- Playhead ---
        if (tl.timeToFrac(tl.current_time)) |head_frac| {
            const head_x = margin + head_frac * bar_w;
            rl.drawCircleV(rl.vec2(head_x, track_y), 8, constants.SCRUBBER_FG);
        }
    }

    const play_text: [*:0]const u8 = if (tl.live) "LIVE" else if (tl.playing) "||" else ">";
    rl.drawTextEx(font, play_text, rl.vec2(20, bar_y + 10), 18, 1.0, constants.SCRUBBER_FG);

    // Click to seek
    if (rl.isMouseButtonDown(rl.MOUSE_BUTTON_LEFT)) {
        const mouse = rl.getMousePosition();
        if (mouse.y >= bar_y and mouse.x >= margin and mouse.x <= margin + bar_w) {
            const click_frac: f64 = @floatCast((mouse.x - margin) / bar_w);
            const click_time = tl.windowStart() + click_frac * tl.window;
            tl.seek(click_time);
        }
    }
}

pub fn drawClusterFilter(filter: *const ClusterFilter, sw: c_int) void {
    const start_x: f32 = @as(f32, @floatFromInt(sw)) - 200;
    const y: f32 = 20;
    const dot_r: f32 = 8;
    const spacing: f32 = 28;

    for (0..constants.NUM_CLUSTERS) |i| {
        const x = start_x + @as(f32, @floatFromInt(i)) * spacing;
        const col = constants.PALETTE[i];
        if (filter.visible[i]) {
            rl.drawCircleV(rl.vec2(x, y), dot_r, col);
        } else {
            rl.drawCircleLinesV(rl.vec2(x, y), dot_r, rl.colorFade(col, 0.3));
        }
    }
}

pub fn drawSearchBar(search: *const SearchState, font: rl.Font, sw: c_int) void {
    if (!search.active) return;
    const w: f32 = 300;
    const h: f32 = 32;
    const x: f32 = @as(f32, @floatFromInt(sw)) / 2 - w / 2;
    const y: f32 = 8;

    rl.drawRectangleRounded(.{ .x = x, .y = y, .width = w, .height = h }, 0.3, 8, constants.SEARCH_BG);
    rl.drawRectangleRoundedLines(.{ .x = x, .y = y, .width = w, .height = h }, 0.3, 8, constants.HUD_COLOR);

    var buf: [80]u8 = undefined;
    _ = printZ(&buf, "/ {s}_", .{search.query()});
    rl.drawTextEx(font, @ptrCast(&buf), rl.vec2(x + 10, y + 8), 14, 1.0, constants.HUD_COLOR);
}

pub fn drawDetailPanel(
    points: []const data.Point,
    idx: u16,
    nd: *const data.NucleusData,
    font: rl.Font,
    sw: c_int,
) void {
    if (idx >= points.len) return;
    const p = points[idx];
    const panel_w: f32 = 260;
    const panel_h: f32 = 200;
    const panel_x: f32 = @as(f32, @floatFromInt(sw)) - panel_w - 10;
    const panel_y: f32 = 50;

    rl.drawRectangleRounded(.{
        .x = panel_x,
        .y = panel_y,
        .width = panel_w,
        .height = panel_h,
    }, 0.05, 8, constants.SEARCH_BG);

    const x = panel_x + 12;
    var y = panel_y + 12;
    const sz: f32 = 14;

    var name_buf: [128]u8 = undefined;
    const word = nd.displayWord(p.name_idx);
    const wlen = @min(word.len, 127);
    @memcpy(name_buf[0..wlen], word[0..wlen]);
    name_buf[wlen] = 0;
    rl.drawTextEx(font, @ptrCast(&name_buf), rl.vec2(x, y), 18, 1.0, constants.HUD_COLOR);
    y += 24;

    const sname = nd.synsetName(p.name_idx);
    var sn_buf: [128]u8 = undefined;
    const slen = @min(sname.len, 127);
    @memcpy(sn_buf[0..slen], sname[0..slen]);
    sn_buf[slen] = 0;
    rl.drawTextEx(font, @ptrCast(&sn_buf), rl.vec2(x, y), 12, 1.0, constants.HUD_DIM);
    y += 18;

    var buf: [64]u8 = undefined;

    _ = printZ(&buf, "Updates: {d:.0}", .{p.total});
    rl.drawTextEx(font, @ptrCast(&buf), rl.vec2(x, y), sz, 1.0, constants.LABEL_COLOR);
    y += sz + 4;

    _ = printZ(&buf, "Exemplars: {d:.0}", .{p.exemplars});
    rl.drawTextEx(font, @ptrCast(&buf), rl.vec2(x, y), sz, 1.0, constants.LABEL_COLOR);
    y += sz + 4;

    _ = printZ(&buf, "Delta: {d:.0}", .{p.delta});
    rl.drawTextEx(font, @ptrCast(&buf), rl.vec2(x, y), sz, 1.0, constants.LABEL_COLOR);
    y += sz + 4;

    _ = printZ(&buf, "Uncertainty: {d:.4}", .{p.uncertainty});
    rl.drawTextEx(font, @ptrCast(&buf), rl.vec2(x, y), sz, 1.0, constants.LABEL_COLOR);
    y += sz + 4;

    const cc = constants.PALETTE[p.cluster % constants.NUM_CLUSTERS];
    rl.drawCircleV(rl.vec2(x + 5, y + sz / 2), 5, cc);
    _ = printZ(&buf, "  Cluster {d}", .{p.cluster});
    rl.drawTextEx(font, @ptrCast(&buf), rl.vec2(x + 12, y), sz, 1.0, constants.LABEL_COLOR);
}

fn printZ(buf: []u8, comptime fmt: []const u8, args: anytype) void {
    const result = std.fmt.bufPrint(buf, fmt, args) catch {
        buf[0] = '?';
        buf[1] = 0;
        return;
    };
    if (result.len < buf.len) {
        buf[result.len] = 0;
    }
}
