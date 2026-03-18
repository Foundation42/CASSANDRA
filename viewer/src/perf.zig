const std = @import("std");
const rl = @import("rl.zig");
const constants = @import("constants.zig");
const js_mod = @import("js.zig");

const NUM_PHASES = 8;
const PHASE_NAMES = [NUM_PHASES][]const u8{
    "Grid",
    "Map",
    "Navmesh",
    "Dots",
    "Glow",
    "Labels",
    "Effects",
    "Overlays",
};

const EMA_ALPHA: f32 = 0.1;
const BAR_COLOR = rl.color(0, 255, 180, 160);
const BAR_BG = rl.color(20, 20, 35, 200);
const TEXT_COLOR = rl.color(0, 255, 180, 200);
const JS_COLOR = rl.color(255, 200, 80, 200);
const JS_BAR_COLOR = rl.color(255, 200, 80, 160);
const JS_MEM_ROWS: f32 = 6;

pub const PerfTimers = struct {
    phase_us: [NUM_PHASES]f32 = [_]f32{0} ** NUM_PHASES,
    total_us: f32 = 0,
    visible: bool = false,

    // Scratch for timing within a frame
    lap_start: i128 = 0,

    // JS runtime ref for memory stats
    js: ?*js_mod.JsRuntime = null,

    pub fn handleInput(self: *PerfTimers) void {
        if (rl.isKeyPressed(rl.c.KEY_P)) {
            self.visible = !self.visible;
        }
    }

    /// Call before a phase begins.
    pub fn lapStart(self: *PerfTimers) void {
        if (self.visible) {
            self.lap_start = std.time.nanoTimestamp();
        }
    }

    /// Call after a phase ends. Records elapsed time into the given phase slot.
    pub fn lapEnd(self: *PerfTimers, phase: usize) void {
        if (!self.visible) return;
        const now = std.time.nanoTimestamp();
        const elapsed_ns = now - self.lap_start;
        const elapsed_us: f32 = @floatFromInt(@divTrunc(elapsed_ns, 1000));
        self.phase_us[phase] = self.phase_us[phase] * (1.0 - EMA_ALPHA) + elapsed_us * EMA_ALPHA;
        self.lap_start = now;
    }

    /// Update total from sum of phases.
    pub fn endFrame(self: *PerfTimers) void {
        if (!self.visible) return;
        var sum: f32 = 0;
        for (self.phase_us) |us| sum += us;
        self.total_us = sum;
    }

    /// Draw the perf HUD in the bottom-right corner.
    pub fn draw(self: *const PerfTimers, font: rl.Font, sw: c_int, sh: c_int) void {
        if (!self.visible) return;

        const panel_w: f32 = 240;
        const line_h: f32 = 14;
        const js_lines: f32 = if (self.js != null) JS_MEM_ROWS + 1.5 else 0; // header + rows + gap
        const panel_h: f32 = line_h * (@as(f32, NUM_PHASES) + 2 + js_lines) + 8;
        const px: f32 = @as(f32, @floatFromInt(sw)) - panel_w - 16;
        const py: f32 = @as(f32, @floatFromInt(sh)) - panel_h - 70;

        // Background
        rl.drawRectangleRounded(.{ .x = px - 4, .y = py - 4, .width = panel_w + 8, .height = panel_h + 8 }, 0.1, 4, BAR_BG);

        // Header
        rl.drawTextEx(font, "PERF (us)", rl.vec2(px, py), 11, 1.0, TEXT_COLOR);

        const budget: f32 = 16667; // 60fps frame budget in us

        // Phase bars
        for (0..NUM_PHASES) |i| {
            const y = py + line_h * (@as(f32, @floatFromInt(i)) + 1.2);
            const us = self.phase_us[i];
            const pct = if (self.total_us > 0) us / budget * 100.0 else 0;

            // Bar
            const bar_max: f32 = 100;
            const bar_w = @min(bar_max, us / budget * bar_max);
            rl.drawRectangleRounded(.{ .x = px + 70, .y = y + 1, .width = bar_w, .height = line_h - 3 }, 0.2, 2, BAR_COLOR);

            // Label
            var name_buf: [16:0]u8 = undefined;
            @memcpy(name_buf[0..PHASE_NAMES[i].len], PHASE_NAMES[i]);
            name_buf[PHASE_NAMES[i].len] = 0;
            rl.drawTextEx(font, &name_buf, rl.vec2(px, y), 10, 1.0, TEXT_COLOR);

            // Value
            var val_buf: [24:0]u8 = undefined;
            const us_int: u32 = @intFromFloat(@min(us, 99999));
            const pct_int: u32 = @intFromFloat(@min(pct, 999));
            const val_len = fmtPerfLine(&val_buf, us_int, pct_int);
            _ = val_len;
            rl.drawTextEx(font, &val_buf, rl.vec2(px + 70 + bar_max + 4, y), 10, 1.0, TEXT_COLOR);
        }

        // Total
        {
            const y = py + line_h * (@as(f32, NUM_PHASES) + 1.5);
            var total_buf: [24:0]u8 = undefined;
            const total_int: u32 = @intFromFloat(@min(self.total_us, 99999));
            const pct_int: u32 = @intFromFloat(@min(if (budget > 0) self.total_us / budget * 100.0 else 0, 999));
            _ = fmtPerfLine(&total_buf, total_int, pct_int);
            rl.drawTextEx(font, "TOTAL", rl.vec2(px, y), 10, 1.0, constants.HUD_COLOR);
            rl.drawTextEx(font, &total_buf, rl.vec2(px + 70, y), 10, 1.0, constants.HUD_COLOR);
        }

        // QuickJS memory section
        if (self.js) |js| {
            const js_y_base = py + line_h * (@as(f32, NUM_PHASES) + 3.0);
            rl.drawTextEx(font, "JS MEMORY", rl.vec2(px, js_y_base), 11, 1.0, JS_COLOR);

            const malloc_bytes = js.mem_malloc_size.load(.acquire);
            const obj_count = js.mem_obj_count.load(.acquire);
            const str_count = js.mem_str_count.load(.acquire);
            const atom_count = js.mem_atom_count.load(.acquire);
            const shape_count = js.mem_shape_count.load(.acquire);
            const func_count = js.mem_js_func_count.load(.acquire);

            const rows = [JS_MEM_ROWS]struct { name: []const u8, val: i64, is_bytes: bool }{
                .{ .name = "Heap", .val = malloc_bytes, .is_bytes = true },
                .{ .name = "Objects", .val = obj_count, .is_bytes = false },
                .{ .name = "Strings", .val = str_count, .is_bytes = false },
                .{ .name = "Atoms", .val = atom_count, .is_bytes = false },
                .{ .name = "Shapes", .val = shape_count, .is_bytes = false },
                .{ .name = "Funcs", .val = func_count, .is_bytes = false },
            };

            for (rows, 0..) |row, i| {
                const y = js_y_base + line_h * (@as(f32, @floatFromInt(i)) + 1.2);

                // Label
                var name_buf: [16:0]u8 = undefined;
                @memcpy(name_buf[0..row.name.len], row.name);
                name_buf[row.name.len] = 0;
                rl.drawTextEx(font, &name_buf, rl.vec2(px, y), 10, 1.0, JS_COLOR);

                // Value
                var val_buf: [24:0]u8 = undefined;
                if (row.is_bytes) {
                    fmtBytes(&val_buf, row.val);
                } else {
                    fmtCount(&val_buf, row.val);
                }
                rl.drawTextEx(font, &val_buf, rl.vec2(px + 70, y), 10, 1.0, JS_COLOR);

                // Bar (heap usage relative to 16MB GC threshold)
                if (row.is_bytes) {
                    const gc_threshold: f32 = 16 * 1024 * 1024;
                    const bar_max: f32 = 100;
                    const ratio = @as(f32, @floatFromInt(row.val)) / gc_threshold;
                    const bar_w = @min(bar_max, ratio * bar_max);
                    rl.drawRectangleRounded(.{ .x = px + 140, .y = y + 1, .width = bar_w, .height = line_h - 3 }, 0.2, 2, JS_BAR_COLOR);
                }
            }
        }
    }
};

/// Phase indices (match PHASE_NAMES order).
pub const GRID = 0;
pub const MAP = 1;
pub const NAVMESH = 2;
pub const DOTS = 3;
pub const GLOW = 4;
pub const LABELS = 5;
pub const EFFECTS = 6;
pub const OVERLAYS = 7;

/// Format "12345 67%" into a sentinel-terminated buffer.
fn fmtPerfLine(buf: *[24:0]u8, us: u32, pct: u32) usize {
    var pos: usize = 0;
    // us value (right-aligned in 5 chars)
    var val = us;
    var digits: [5]u8 = undefined;
    var d: usize = 0;
    if (val == 0) {
        digits[0] = '0';
        d = 1;
    } else {
        while (val > 0 and d < 5) : (d += 1) {
            digits[d] = '0' + @as(u8, @intCast(val % 10));
            val /= 10;
        }
    }
    // Pad with spaces
    for (0..(5 - d)) |_| {
        buf[pos] = ' ';
        pos += 1;
    }
    // Write digits in reverse
    var i = d;
    while (i > 0) {
        i -= 1;
        buf[pos] = digits[i];
        pos += 1;
    }
    buf[pos] = ' ';
    pos += 1;
    // pct
    var pval = pct;
    var pd: [3]u8 = undefined;
    var pd_len: usize = 0;
    if (pval == 0) {
        pd[0] = '0';
        pd_len = 1;
    } else {
        while (pval > 0 and pd_len < 3) : (pd_len += 1) {
            pd[pd_len] = '0' + @as(u8, @intCast(pval % 10));
            pval /= 10;
        }
    }
    i = pd_len;
    while (i > 0) {
        i -= 1;
        buf[pos] = pd[i];
        pos += 1;
    }
    buf[pos] = '%';
    pos += 1;
    buf[pos] = 0;
    return pos;
}

/// Format byte count as human-readable (e.g. "1.23 MB", "456 KB").
fn fmtBytes(buf: *[24:0]u8, bytes: i64) void {
    const b: u64 = @intCast(@max(bytes, 0));
    if (b >= 1024 * 1024) {
        // MB with one decimal
        const mb_x10 = b * 10 / (1024 * 1024);
        const whole: u32 = @intCast(mb_x10 / 10);
        const frac: u32 = @intCast(mb_x10 % 10);
        _ = std.fmt.bufPrint(buf, "{d}.{d} MB", .{ whole, frac }) catch {};
        buf[std.mem.indexOf(u8, buf, "B").? + 1] = 0;
    } else if (b >= 1024) {
        const kb: u32 = @intCast(b / 1024);
        _ = std.fmt.bufPrint(buf, "{d} KB", .{kb}) catch {};
        buf[std.mem.indexOf(u8, buf, "B").? + 1] = 0;
    } else {
        const bv: u32 = @intCast(b);
        _ = std.fmt.bufPrint(buf, "{d} B", .{bv}) catch {};
        buf[std.mem.indexOf(u8, buf, "B").? + 1] = 0;
    }
}

/// Format an integer count into a sentinel-terminated buffer.
fn fmtCount(buf: *[24:0]u8, count: i64) void {
    const v: u64 = @intCast(@max(count, 0));
    if (v >= 1000) {
        const k_x10 = v * 10 / 1000;
        const whole: u32 = @intCast(@min(k_x10 / 10, 9999));
        const frac: u32 = @intCast(k_x10 % 10);
        const len = (std.fmt.bufPrint(buf, "{d}.{d}k", .{ whole, frac }) catch "").len;
        buf[len] = 0;
    } else {
        const vi: u32 = @intCast(v);
        const len = (std.fmt.bufPrint(buf, "{d}", .{vi}) catch "").len;
        buf[len] = 0;
    }
}
