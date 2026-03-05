const std = @import("std");
const rl = @import("rl.zig");
const data = @import("data.zig");
const constants = @import("constants.zig");

/// Parse "YYYYMMDD_HHMMSS" to seconds since epoch (approximate, for relative spacing)
fn parseTimestamp(ts: []const u8) i64 {
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

pub const Timeline = struct {
    current_time: f32 = 0.0,
    playing: bool = false,
    speed_idx: u8 = 2, // default 0.1x
    num_keyframes: u32 = 0,
    tick_fracs: ?[]f32 = null, // timestamp-proportional positions [0..1]
    follow_target: ?f32 = null, // live-follow: smoothly drift towards this time

    pub fn init(num_kf: u32) Timeline {
        return .{
            .num_keyframes = num_kf,
            .current_time = if (num_kf > 0) @as(f32, @floatFromInt(num_kf - 1)) else 0,
        };
    }

    /// Returns true if the playhead is at (or very near) the end of the timeline
    pub fn wasAtEnd(self: *const Timeline) bool {
        const max_t: f32 = @floatFromInt(self.num_keyframes -| 1);
        return self.current_time >= max_t - 0.01;
    }

    /// Compute proportional tick positions from timestamp strings like "20260304_190133"
    pub fn computeTickFracs(self: *Timeline, keyframes: []const data.Keyframe, allocator: std.mem.Allocator) !void {
        if (keyframes.len < 2) return;
        // Free previous allocation
        if (self.tick_fracs) |old| allocator.free(old);
        const n = keyframes.len;
        self.tick_fracs = try allocator.alloc(f32, n);
        const fracs = self.tick_fracs.?;

        // Parse each timestamp to comparable seconds
        const times = try allocator.alloc(i64, n);
        defer allocator.free(times);
        for (keyframes, 0..) |kf, i| {
            times[i] = parseTimestamp(kf.timestamp);
        }

        const t0 = times[0];
        const t_last = times[n - 1];
        const span = t_last - t0;
        if (span <= 0) {
            // Fallback to uniform
            for (0..n) |i| {
                fracs[i] = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n - 1));
            }
            return;
        }

        for (0..n) |i| {
            fracs[i] = @as(f32, @floatFromInt(times[i] - t0)) / @as(f32, @floatFromInt(span));
        }
    }

    pub fn update(self: *Timeline, dt: f32) void {
        const max_t: f32 = @floatFromInt(self.num_keyframes -| 1);

        // Live-follow: smoothly drift towards target (~4s per keyframe)
        if (self.follow_target) |target| {
            const drift_speed: f32 = 0.25; // keyframes per second
            const diff = target - self.current_time;
            if (@abs(diff) < 0.01) {
                self.current_time = target;
                self.follow_target = null;
            } else {
                self.current_time += diff * @min(drift_speed * dt * 3.0, 1.0);
            }
        }

        if (self.playing and self.num_keyframes >= 2) {
            const spd = constants.SPEED_LEVELS[self.speed_idx];
            self.current_time += spd * dt;
            if (self.current_time >= max_t) {
                self.current_time = max_t;
                self.playing = false;
            }
        }

        self.current_time = std.math.clamp(self.current_time, 0, max_t);
    }

    pub fn handleInput(self: *Timeline) void {
        if (rl.isKeyPressed(rl.KEY_SPACE)) {
            self.playing = !self.playing;
            self.follow_target = null;
            const max_t: f32 = @floatFromInt(self.num_keyframes - 1);
            if (self.current_time >= max_t and self.playing) {
                self.current_time = 0;
            }
        }
        if (rl.isKeyPressed(rl.KEY_RIGHT_BRACKET)) {
            if (self.speed_idx < constants.SPEED_LEVELS.len - 1) self.speed_idx += 1;
        }
        if (rl.isKeyPressed(rl.KEY_LEFT_BRACKET)) {
            if (self.speed_idx > 0) self.speed_idx -= 1;
        }
        if (rl.isKeyPressed(rl.KEY_RIGHT)) {
            self.current_time = @min(self.current_time + 1.0, @as(f32, @floatFromInt(self.num_keyframes - 1)));
            self.playing = false;
            self.follow_target = null;
        }
        if (rl.isKeyPressed(rl.KEY_LEFT)) {
            self.current_time = @max(self.current_time - 1.0, 0.0);
            self.playing = false;
            self.follow_target = null;
        }
    }

    pub fn speed(self: *const Timeline) f32 {
        return constants.SPEED_LEVELS[self.speed_idx];
    }

    pub fn keyframeIndex(self: *const Timeline) u32 {
        return @intFromFloat(@floor(self.current_time));
    }

    pub fn interpFraction(self: *const Timeline) f32 {
        return self.current_time - @floor(self.current_time);
    }

    pub fn seek(self: *Timeline, t: f32) void {
        const max_t: f32 = @floatFromInt(self.num_keyframes - 1);
        self.current_time = std.math.clamp(t, 0, max_t);
        self.follow_target = null;
    }
};

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
    // Simple hash spread: multiply by golden ratio fraction, take fractional part
    const h = @as(u32, name_idx) *% 2654435761;
    return @as(f32, @floatFromInt(h >> 22)) / @as(f32, @floatFromInt(1 << 10)) * 0.7;
}

/// Remap global t [0..1] into a per-point t that starts at `offset` and
/// reaches 1.0 by the end. Points with higher offsets appear later.
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
            // Stagger delta changes: points that gain activity ramp up at different times
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
            // Stagger new point appearance across the transition
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
