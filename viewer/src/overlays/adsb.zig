const std = @import("std");
const rl = @import("../rl.zig");
const overlay = @import("../overlay.zig");
const worldmap_mod = @import("../worldmap.zig");

const MAX_AIRCRAFT: usize = 8192;
const POLL_INTERVAL_NS: u64 = 10 * std.time.ns_per_s;
const DOT_COLOR = rl.color(255, 220, 50, 200); // yellow
const LABEL_COLOR = rl.color(255, 220, 50, 140);
const HEADING_COLOR = rl.color(255, 220, 50, 100);

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
            rl.drawCircleV(pos, 0.06, DOT_COLOR);

            // Heading indicator
            if (ac.heading != 0) {
                const rad = (ac.heading - 90.0) * std.math.pi / 180.0;
                const len: f32 = 0.2;
                const end = rl.vec2(ac.x + @cos(rad) * len, ac.y + @sin(rad) * len);
                rl.drawLineEx(pos, end, 0.03, HEADING_COLOR);
            }
        }
    }

    pub fn drawScreen(self: *AdsbOverlay, fctx: *const overlay.FrameContext) void {
        // Draw callsign labels for aircraft near center of screen
        const cam = fctx.cam;
        for (self.aircraft[0..self.count]) |ac| {
            if (ac.on_ground or ac.callsign_len == 0) continue;
            if (cam.zoom < 2.0) continue; // only show labels when zoomed in

            const screen = rl.getWorldToScreen2D(rl.vec2(ac.x, ac.y), cam);
            if (screen.x < 0 or screen.y < 0) continue;
            if (screen.x > @as(f32, @floatFromInt(fctx.sw)) or screen.y > @as(f32, @floatFromInt(fctx.sh))) continue;

            var label_buf: [9:0]u8 = undefined;
            @memcpy(label_buf[0..ac.callsign_len], ac.callsign[0..ac.callsign_len]);
            label_buf[ac.callsign_len] = 0;
            rl.drawTextEx(fctx.font, &label_buf, rl.vec2(screen.x + 5, screen.y - 5), 9, 1.0, LABEL_COLOR);
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

        while (!self.shutdown.load(.acquire)) {
            self.fetchAndParse(&client);
            // Sleep in small increments to allow quick shutdown
            var slept: u64 = 0;
            while (slept < POLL_INTERVAL_NS and !self.shutdown.load(.acquire)) {
                std.time.sleep(500 * std.time.ns_per_ms);
                slept += 500 * std.time.ns_per_ms;
            }
        }
    }

    fn fetchAndParse(self: *AdsbOverlay, client: *std.http.Client) void {
        const url = "https://opensky-network.org/api/states/all";
        const uri = std.Uri.parse(url) catch return;

        var buf: [1024 * 1024 * 4]u8 = undefined; // 4MB buffer
        var req = client.open(.GET, uri, .{
            .server_header_buffer = &buf,
        }) catch {
            self.last_fetch_status = .err;
            return;
        };
        defer req.deinit();

        req.send() catch {
            self.last_fetch_status = .err;
            return;
        };
        req.finish() catch {
            self.last_fetch_status = .err;
            return;
        };
        req.wait() catch {
            self.last_fetch_status = .err;
            return;
        };

        if (req.response.status != .ok) {
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

fn jsonFloat(val: std.json.Value) f64 {
    return switch (val) {
        .float => val.float,
        .integer => @floatFromInt(val.integer),
        else => 0,
    };
}
