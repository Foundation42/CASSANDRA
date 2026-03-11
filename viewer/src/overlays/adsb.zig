const std = @import("std");
const rl = @import("../rl.zig");
const overlay = @import("../overlay.zig");
const worldmap_mod = @import("../worldmap.zig");

const MAX_AIRCRAFT: usize = 8192;
const MAX_LABELS: usize = 200;
const POLL_INTERVAL_NS: u64 = 10 * std.time.ns_per_s;
const HEADING_ALPHA: u8 = 100;

pub const Aircraft = struct {
    x: f32, // world coords
    y: f32,
    heading: f32 = 0, // degrees, 0 = north
    callsign: [8]u8 = .{0} ** 8,
    callsign_len: u8 = 0,
    altitude: f32 = 0, // meters
    velocity: f32 = 0, // m/s
    on_ground: bool = false,
};

pub const AdsbOverlay = struct {
    active: bool = false,
    aircraft: [MAX_AIRCRAFT]Aircraft = undefined,
    count: usize = 0,
    // Double-buffered: worker writes to pending, main thread swaps
    mutex: std.Thread.Mutex = .{},
    pending_aircraft: [MAX_AIRCRAFT]Aircraft = undefined,
    pending_count: usize = 0,
    has_pending: bool = false,
    worker: ?std.Thread = null,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_fetch_status: enum { idle, ok, err } = .idle,

    pub fn enabled(self: *const AdsbOverlay) bool {
        return self.active;
    }

    pub fn handleToggle(self: *AdsbOverlay) void {
        if (rl.isKeyPressed(rl.c.KEY_A)) {
            self.active = !self.active;
            if (self.active and self.worker == null) {
                self.shutdown.store(false, .release);
                self.worker = std.Thread.spawn(.{}, workerLoop, .{self}) catch null;
            }
        }
    }

    pub fn update(self: *AdsbOverlay, _: *const overlay.FrameContext) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.has_pending) {
            @memcpy(self.aircraft[0..self.pending_count], self.pending_aircraft[0..self.pending_count]);
            self.count = self.pending_count;
            self.has_pending = false;
        }
    }

    pub fn drawWorld(self: *AdsbOverlay, _: *const overlay.FrameContext) void {
        for (self.aircraft[0..self.count]) |ac| {
            if (ac.on_ground) continue;
            const pos = rl.vec2(ac.x, ac.y);
            const col = altitudeColor(ac.altitude);
            rl.drawCircleV(pos, 0.05, col);

            // Heading indicator
            if (ac.heading != 0) {
                const rad = (ac.heading - 90.0) * std.math.pi / 180.0;
                const len: f32 = 0.1;
                const end = rl.vec2(ac.x + @cos(rad) * len, ac.y + @sin(rad) * len);
                rl.drawLineEx(pos, end, 0.015, rl.colorAlpha(col, HEADING_ALPHA));
            }
        }
    }

    pub fn drawScreen(self: *AdsbOverlay, fctx: *const overlay.FrameContext) void {
        const cam = fctx.cam;
        const sw_f: f32 = @floatFromInt(fctx.sw);
        const sh_f: f32 = @floatFromInt(fctx.sh);
        const margin: f32 = 50;

        const budget = acLabelBudget(cam.zoom);
        const imp_thresh = acLabelThreshold(cam.zoom);
        if (budget == 0) return;

        // Pass 1: collect top-K labels by importance (viewport-culled)
        const LabelSlot = struct { idx: u16, importance: f32, screen_x: f32, screen_y: f32 };
        var slots: [MAX_LABELS]LabelSlot = undefined;
        var n_slots: usize = 0;
        var min_imp: f32 = 0;
        var min_idx: usize = 0;

        for (self.aircraft[0..self.count], 0..) |ac, i| {
            if (ac.on_ground or ac.callsign_len == 0) continue;
            const screen = rl.getWorldToScreen2D(rl.vec2(ac.x, ac.y), cam);
            if (screen.x < -margin or screen.x > sw_f + margin or screen.y < -margin or screen.y > sh_f + margin) continue;

            const imp = acImportance(ac, cam.zoom);
            if (imp < imp_thresh) continue;

            if (n_slots < budget) {
                slots[n_slots] = .{ .idx = @intCast(i), .importance = imp, .screen_x = screen.x, .screen_y = screen.y };
                n_slots += 1;
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
                slots[min_idx] = .{ .idx = @intCast(i), .importance = imp, .screen_x = screen.x, .screen_y = screen.y };
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

        // Pass 2: draw budgeted labels with alpha fade
        const threshold: f32 = if (n_slots == budget) min_imp else imp_thresh;
        const zoom_scale = 1.0 + std.math.clamp((cam.zoom - 2.0) * 0.08, 0.0, 1.0);
        const font_size: f32 = 9.0 * zoom_scale;

        for (slots[0..n_slots]) |slot| {
            const above = slot.importance - threshold;
            const range: f32 = 0.5;
            const alpha = std.math.clamp(above / (range * 0.3), 0.15, 1.0);
            const ac = self.aircraft[slot.idx];
            const base = altitudeColor(ac.altitude);
            const a: u8 = @intFromFloat(alpha * @as(f32, @floatFromInt(base.a)));
            const col = rl.colorAlpha(base, a);
            var label_buf: [9:0]u8 = undefined;
            @memcpy(label_buf[0..ac.callsign_len], ac.callsign[0..ac.callsign_len]);
            label_buf[ac.callsign_len] = 0;
            rl.drawTextEx(fctx.font, &label_buf, rl.vec2(slot.screen_x + 5, slot.screen_y - 5), font_size, 1.0, col);
        }
    }

    pub fn statusText(_: *const AdsbOverlay, buf: []u8) usize {
        const tag = "ADSB";
        if (buf.len < tag.len + 3) return 0;
        // Prepend separator if there's already content
        var pos: usize = 0;
        @memcpy(buf[pos..][0..tag.len], tag);
        pos += tag.len;
        return pos;
    }

    fn workerLoop(self: *AdsbOverlay) void {
        var client = std.http.Client{ .allocator = std.heap.page_allocator };
        defer client.deinit();
        var backoff: u64 = POLL_INTERVAL_NS;

        while (!self.shutdown.load(.acquire)) {
            self.fetchAndParse(&client);
            const sleep_ns = if (self.last_fetch_status == .err) blk: {
                backoff = @min(backoff * 2, 120 * std.time.ns_per_s); // max 2min
                std.debug.print("ADSB: backing off {d}s\n", .{backoff / std.time.ns_per_s});
                break :blk backoff;
            } else blk: {
                backoff = POLL_INTERVAL_NS; // reset on success
                break :blk POLL_INTERVAL_NS;
            };
            var slept: u64 = 0;
            while (slept < sleep_ns and !self.shutdown.load(.acquire)) {
                std.time.sleep(500 * std.time.ns_per_ms);
                slept += 500 * std.time.ns_per_ms;
            }
        }
    }

    fn fetchAndParse(self: *AdsbOverlay, client: *std.http.Client) void {
        const url = "https://opensky-network.org/api/states/all";
        const uri = std.Uri.parse(url) catch return;

        std.debug.print("ADSB: fetching...\n", .{});
        var buf: [1024 * 1024 * 4]u8 = undefined; // 4MB buffer
        var req = client.open(.GET, uri, .{
            .server_header_buffer = &buf,
        }) catch |err| {
            std.debug.print("ADSB: open failed: {}\n", .{err});
            self.last_fetch_status = .err;
            return;
        };
        defer req.deinit();

        req.send() catch |err| {
            std.debug.print("ADSB: send failed: {}\n", .{err});
            self.last_fetch_status = .err;
            return;
        };
        req.finish() catch |err| {
            std.debug.print("ADSB: finish failed: {}\n", .{err});
            self.last_fetch_status = .err;
            return;
        };
        req.wait() catch |err| {
            std.debug.print("ADSB: wait failed: {}\n", .{err});
            self.last_fetch_status = .err;
            return;
        };

        if (req.response.status == .too_many_requests) {
            std.debug.print("ADSB: rate limited (429)\n", .{});
            self.last_fetch_status = .err;
            return;
        }
        if (req.response.status != .ok) {
            std.debug.print("ADSB: HTTP {}\n", .{req.response.status});
            self.last_fetch_status = .err;
            return;
        }

        // Read response body
        var body = std.ArrayList(u8).init(std.heap.page_allocator);
        defer body.deinit();
        var reader = req.reader();
        reader.readAllArrayList(&body, 8 * 1024 * 1024) catch {
            self.last_fetch_status = .err;
            return;
        };

        // Parse JSON: { "states": [[icao24, callsign, origin, time_pos, last_contact, lon, lat, baro_alt, on_ground, velocity, true_track, ...], ...] }
        self.parseStates(body.items);
    }

    fn parseStates(self: *AdsbOverlay, body: []const u8) void {
        var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch {
            self.last_fetch_status = .err;
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        const states_val = root.object.get("states") orelse {
            self.last_fetch_status = .err;
            return;
        };
        const states = states_val.array.items;

        var tmp: [MAX_AIRCRAFT]Aircraft = undefined;
        var count: usize = 0;

        for (states) |state_val| {
            if (count >= MAX_AIRCRAFT) break;
            const state = state_val.array.items;
            if (state.len < 12) continue;

            // lon = index 5, lat = index 6
            const lon_val = state[5];
            const lat_val = state[6];
            if (lon_val == .null or lat_val == .null) continue;

            const lon: f32 = @floatCast(jsonFloat(lon_val));
            const lat: f32 = @floatCast(jsonFloat(lat_val));
            const world_pos = worldmap_mod.latLonToWorld(lat, lon);

            var ac = Aircraft{
                .x = world_pos[0],
                .y = world_pos[1],
            };

            // callsign (index 1)
            if (state[1] == .string) {
                const cs = state[1].string;
                const cs_trimmed = std.mem.trimRight(u8, cs, " ");
                const copy_len = @min(cs_trimmed.len, 8);
                @memcpy(ac.callsign[0..copy_len], cs_trimmed[0..copy_len]);
                ac.callsign_len = @intCast(copy_len);
            }

            // baro_alt (index 7)
            if (state[7] != .null) ac.altitude = @floatCast(jsonFloat(state[7]));

            // on_ground (index 8)
            if (state[8] == .bool) ac.on_ground = state[8].bool;

            // velocity (index 9)
            if (state[9] != .null) ac.velocity = @floatCast(jsonFloat(state[9]));

            // true_track / heading (index 10)
            if (state[10] != .null) ac.heading = @floatCast(jsonFloat(state[10]));

            tmp[count] = ac;
            count += 1;
        }

        // Publish
        self.mutex.lock();
        defer self.mutex.unlock();
        @memcpy(self.pending_aircraft[0..count], tmp[0..count]);
        self.pending_count = count;
        self.has_pending = true;
        self.last_fetch_status = .ok;
        std.debug.print("ADSB: parsed {d} aircraft\n", .{count});
    }
};

/// Altitude color ramp (FlightRadar24 style):
///   ground–2km  green      (0, 200, 0)
///   2km–5km     yellow     (220, 220, 0)
///   5km–8km     orange     (255, 140, 0)
///   8km–11km    red        (255, 50, 50)
///   11km+       purple     (200, 80, 255)
fn altitudeColor(alt_m: f32) rl.Color {
    // Guard against NaN / Inf from API data
    if (!std.math.isFinite(alt_m)) return rl.color(255, 220, 50, 200); // fallback yellow

    // Ramp stops: altitude (meters) → RGB
    const alts = [_]f32{ 0, 2000, 5000, 8000, 11000 };
    const rs = [_]f32{ 50, 220, 255, 255, 200 };
    const gs = [_]f32{ 220, 220, 140, 50, 80 };
    const bs = [_]f32{ 50, 0, 0, 50, 255 };

    const alt = @max(@min(alt_m, 11000.0), 0.0);
    var i: usize = 0;
    while (i < alts.len - 2 and alt > alts[i + 1]) : (i += 1) {}
    const span = alts[i + 1] - alts[i];
    const t = if (span > 0) @max(@min((alt - alts[i]) / span, 1.0), 0.0) else 0.0;
    return rl.color(
        @intFromFloat(@max(@min(rs[i] + (rs[i + 1] - rs[i]) * t, 255.0), 0.0)),
        @intFromFloat(@max(@min(gs[i] + (gs[i + 1] - gs[i]) * t, 255.0), 0.0)),
        @intFromFloat(@max(@min(bs[i] + (bs[i + 1] - bs[i]) * t, 255.0), 0.0)),
        200,
    );
}

/// Aircraft importance: altitude-based (high-altitude = more visible) + zoom reveal.
fn acImportance(ac: Aircraft, zoom: f32) f32 {
    const alt_norm = std.math.clamp(ac.altitude / 12000.0, 0.0, 1.0); // 0-12km
    const spd_norm = std.math.clamp(ac.velocity / 300.0, 0.0, 1.0); // 0-300 m/s
    const zoom_reveal = std.math.clamp((zoom - 40.0) / 100.0, 0.0, 1.0);
    return @max(alt_norm * 0.6 + spd_norm * 0.4, zoom_reveal);
}

/// Label budget: 0 below zoom 30, ramps to MAX_LABELS at deep zoom.
fn acLabelBudget(zoom: f32) usize {
    if (zoom < 30.0) return 0;
    const t = std.math.clamp((zoom - 30.0) / 60.0, 0.0, 1.0);
    const t2 = std.math.clamp((zoom - 80.0) / 200.0, 0.0, 1.0);
    return @intFromFloat(6.0 + 44.0 * t + @as(f32, MAX_LABELS - 50) * t2);
}

/// Threshold: stricter when zoomed out, relaxes as you zoom in.
fn acLabelThreshold(zoom: f32) f32 {
    const t = std.math.clamp((zoom - 30.0) / 100.0, 0.0, 1.0);
    return 0.5 - 0.5 * t;
}

fn jsonFloat(val: std.json.Value) f64 {
    return switch (val) {
        .float => val.float,
        .integer => @floatFromInt(val.integer),
        else => 0,
    };
}
