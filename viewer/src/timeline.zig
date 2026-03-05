const std = @import("std");
const rl = @import("rl.zig");
const data = @import("data.zig");
const constants = @import("constants.zig");

/// Parse "YYYYMMDD_HHMMSS" to seconds since epoch (approximate, for relative spacing)
pub fn parseTimestamp(ts: []const u8) i64 {
    // Need at least "YYYYMMDD_HHMMSS" = 15 chars
    if (ts.len < 15) return 0;
    const y = parseInt(ts[0..4]);
    const mo = parseInt(ts[4..6]);
    const d = parseInt(ts[6..8]);
    // ts[8] == '_'
    const h = parseInt(ts[9..11]);
    const mi = parseInt(ts[11..13]);
    const s = parseInt(ts[13..15]);
    // Approximate: good enough for relative spacing
    return @as(i64, y) * 31536000 + @as(i64, mo) * 2592000 + @as(i64, d) * 86400 +
        @as(i64, h) * 3600 + @as(i64, mi) * 60 + @as(i64, s);
}

fn parseInt(buf: []const u8) i32 {
    var v: i32 = 0;
    for (buf) |ch| {
        if (ch >= '0' and ch <= '9') {
            v = v * 10 + @as(i32, ch - '0');
        }
    }
    return v;
}

/// Wall-clock timeline. The playhead and all keyframes live in absolute seconds.
/// The scrubber shows a fixed-width time window that slides as time passes.
pub const Timeline = struct {
    /// Playhead position in wall-clock seconds
    current_time: f64 = 0,
    /// Visible window duration in seconds (default 24 hours)
    window: f64 = 24 * 3600,
    /// When true, playhead tracks "now" (latest keyframe time)
    live: bool = true,
    /// Playback mode: replay from current position at speed_idx rate
    playing: bool = false,
    speed_idx: u8 = 2,
    /// Latest keyframe wall time (updated on arrival)
    latest_time: f64 = 0,
    /// Earliest keyframe wall time
    earliest_time: f64 = 0,

    pub fn init() Timeline {
        return .{};
    }

    /// Call when a new keyframe arrives. Updates the time range.
    pub fn noteArrival(self: *Timeline, wall_time: i64) void {
        const t: f64 = @floatFromInt(wall_time);
        if (t > self.latest_time) self.latest_time = t;
        if (self.earliest_time == 0 or t < self.earliest_time) self.earliest_time = t;
        if (self.live) {
            self.current_time = self.latest_time;
        }
    }

    /// Call when an old keyframe is evicted.
    pub fn noteEviction(self: *Timeline, keyframes: []const data.Keyframe) void {
        if (keyframes.len > 0) {
            self.earliest_time = @floatFromInt(keyframes[0].wall_time);
        }
    }

    pub fn update(self: *Timeline, dt: f32) void {
        if (self.playing) {
            // Replay: advance at selected speed (speed is a time multiplier)
            const spd: f64 = @floatCast(constants.SPEED_LEVELS[self.speed_idx]);
            self.current_time += spd * @as(f64, @floatCast(dt));
            if (self.current_time >= self.latest_time) {
                self.current_time = self.latest_time;
                self.playing = false;
                self.live = true;
            }
        } else if (self.live) {
            self.current_time = self.latest_time;
        }
    }

    pub fn handleInput(self: *Timeline) void {
        if (self.latest_time == 0) return;
        if (rl.isKeyPressed(rl.KEY_SPACE)) {
            if (self.live) {
                // Start playback from the beginning of the window
                self.live = false;
                self.playing = true;
                self.current_time = self.windowStart();
            } else if (self.playing) {
                self.playing = false;
            } else {
                // Resume playback from current position
                self.playing = true;
            }
        }
        // Speed controls
        if (rl.isKeyPressed(rl.KEY_RIGHT_BRACKET)) {
            if (self.speed_idx < constants.SPEED_LEVELS.len - 1) self.speed_idx += 1;
        }
        if (rl.isKeyPressed(rl.KEY_LEFT_BRACKET)) {
            if (self.speed_idx > 0) self.speed_idx -= 1;
        }
        // Step forward/back by 1/20th of the window
        const step = self.window / 20.0;
        if (rl.isKeyPressed(rl.KEY_RIGHT)) {
            self.current_time = @min(self.current_time + step, self.latest_time);
            self.live = false;
            self.playing = false;
        }
        if (rl.isKeyPressed(rl.KEY_LEFT)) {
            self.current_time = @max(self.current_time - step, self.earliest_time);
            self.live = false;
            self.playing = false;
        }
        // End key: snap to live
        if (rl.isKeyPressed(rl.KEY_END)) {
            self.live = true;
            self.playing = false;
            self.current_time = self.latest_time;
        }
    }

    pub fn speed(self: *const Timeline) f32 {
        return constants.SPEED_LEVELS[self.speed_idx];
    }

    pub fn seek(self: *Timeline, t: f64) void {
        self.current_time = std.math.clamp(t, self.earliest_time, self.latest_time);
        self.live = false;
        self.playing = false;
    }

    /// Left edge of the visible window
    pub fn windowStart(self: *const Timeline) f64 {
        return self.latest_time - self.window;
    }

    /// Map a wall-clock time to a fraction [0..1] within the visible window.
    /// Returns null if outside the window.
    pub fn timeToFrac(self: *const Timeline, t: f64) ?f32 {
        const ws = self.windowStart();
        if (self.window <= 0) return null;
        const frac = (t - ws) / self.window;
        if (frac < -0.01 or frac > 1.01) return null;
        return @floatCast(std.math.clamp(frac, 0.0, 1.0));
    }

    /// Find the two keyframes bracketing current_time and the interpolation fraction.
    /// Returns (index_a, index_b, frac) where frac is 0..1 between them.
    /// If current_time is before first or after last, returns the boundary keyframe.
    pub fn findBracket(self: *const Timeline, keyframes: []const data.Keyframe) struct { a: usize, b: usize, frac: f32 } {
        if (keyframes.len == 0) return .{ .a = 0, .b = 0, .frac = 0 };
        if (keyframes.len == 1) return .{ .a = 0, .b = 0, .frac = 0 };

        const ct = self.current_time;

        // Before first keyframe
        const first_t: f64 = @floatFromInt(keyframes[0].wall_time);
        if (ct <= first_t) return .{ .a = 0, .b = 0, .frac = 0 };

        // After last keyframe
        const last_t: f64 = @floatFromInt(keyframes[keyframes.len - 1].wall_time);
        if (ct >= last_t) return .{ .a = keyframes.len - 1, .b = keyframes.len - 1, .frac = 0 };

        // Binary search for the interval
        var lo: usize = 0;
        var hi: usize = keyframes.len - 1;
        while (lo + 1 < hi) {
            const mid = (lo + hi) / 2;
            const mid_t: f64 = @floatFromInt(keyframes[mid].wall_time);
            if (ct < mid_t) {
                hi = mid;
            } else {
                lo = mid;
            }
        }

        const ta: f64 = @floatFromInt(keyframes[lo].wall_time);
        const tb: f64 = @floatFromInt(keyframes[hi].wall_time);
        const span = tb - ta;
        const frac: f32 = if (span > 0) @floatCast((ct - ta) / span) else 0;
        return .{ .a = lo, .b = hi, .frac = std.math.clamp(frac, 0.0, 1.0) };
    }
};

// --- Interpolation ---

pub fn smoothstep(t: f32) f32 {
    const x = std.math.clamp(t, 0.0, 1.0);
    return x * x * (3.0 - 2.0 * x);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// Deterministic stagger offset [0..0.7] from a name index, so each point
/// gets a different "start time" within the transition window.
fn nameStagger(name_idx: u16) f32 {
    const h = @as(u32, name_idx) *% 2654435761;
    return @as(f32, @floatFromInt(h >> 22)) / @as(f32, @floatFromInt(1 << 10)) * 0.7;
}

fn staggeredT(global_t: f32, offset: f32) f32 {
    const remaining = 1.0 - offset;
    if (remaining <= 0) return global_t;
    return smoothstep(std.math.clamp((global_t - offset) / remaining, 0.0, 1.0));
}

pub fn lerpPoints(
    a: []const data.Point,
    b: []const data.Point,
    t: f32,
    allocator: std.mem.Allocator,
) ![]data.Point {
    const s = smoothstep(t);
    var b_map = std.AutoHashMap(u16, usize).init(allocator);
    defer b_map.deinit();
    for (b, 0..) |bp, i| {
        try b_map.put(bp.name_idx, i);
    }

    var result = std.ArrayList(data.Point).init(allocator);

    for (a) |ap| {
        if (b_map.get(ap.name_idx)) |bi| {
            const bp = b[bi];
            const stagger_offset = nameStagger(ap.name_idx);
            const ds = staggeredT(s, stagger_offset);
            try result.append(.{
                .name_idx = ap.name_idx,
                .x = ap.x,
                .y = ap.y,
                .total = lerp(ap.total, bp.total, s),
                .exemplars = lerp(ap.exemplars, bp.exemplars, s),
                .delta = lerp(ap.delta, bp.delta, ds),
                .uncertainty = lerp(ap.uncertainty, bp.uncertainty, s),
                .u_shift = lerp(ap.u_shift, bp.u_shift, s),
                .fade = lerp(ap.fade, bp.fade, s),
                .cluster = if (s < 0.5) ap.cluster else bp.cluster,
                .is_attractor = ap.is_attractor or bp.is_attractor,
                .nearest_attractor = if (s < 0.5) ap.nearest_attractor else bp.nearest_attractor,
            });
        } else {
            var faded = ap;
            faded.fade *= (1.0 - s);
            try result.append(faded);
        }
    }

    for (b) |bp| {
        var found = false;
        for (a) |ap| {
            if (ap.name_idx == bp.name_idx) {
                found = true;
                break;
            }
        }
        if (!found) {
            const stagger_offset = nameStagger(bp.name_idx);
            const ss = staggeredT(s, stagger_offset);
            var fading_in = bp;
            fading_in.fade *= ss;
            fading_in.delta *= ss;
            try result.append(fading_in);
        }
    }

    return try result.toOwnedSlice();
}
