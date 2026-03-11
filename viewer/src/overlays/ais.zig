const std = @import("std");
const rl = @import("../rl.zig");
const overlay = @import("../overlay.zig");
const worldmap_mod = @import("../worldmap.zig");

const MAX_VESSELS: usize = 8192;
const POLL_INTERVAL_NS: u64 = 60 * std.time.ns_per_s;
const DOT_COLOR = rl.color(80, 160, 255, 200); // blue
const LABEL_COLOR = rl.color(80, 160, 255, 140);
const HEADING_COLOR = rl.color(80, 160, 255, 100);

pub const Vessel = struct {
    x: f32, // world coords
    y: f32,
    course: f32 = 0, // degrees
    name: [20]u8 = .{0} ** 20,
    name_len: u8 = 0,
    mmsi: u32 = 0,
    speed: f32 = 0, // knots
    ship_type: u8 = 0,
};

const DataSource = enum { aishub, digitraffic };

pub const AisOverlay = struct {
    active: bool = false,
    vessels: [MAX_VESSELS]Vessel = undefined,
    count: usize = 0,
    mutex: std.Thread.Mutex = .{},
    pending_vessels: [MAX_VESSELS]Vessel = undefined,
    pending_count: usize = 0,
    has_pending: bool = false,
    worker: ?std.Thread = null,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_fetch_status: enum { idle, ok, err } = .idle,
    source: DataSource = .digitraffic,
    aishub_username: ?[]const u8 = null,

    pub fn enabled(self: *const AisOverlay) bool {
        return self.active;
    }

    pub fn handleToggle(self: *AisOverlay) void {
        if (rl.isKeyPressed(rl.c.KEY_S)) {
            self.active = !self.active;
            if (self.active and self.worker == null) {
                // Check for AISHub credentials (global coverage)
                self.aishub_username = std.posix.getenv("AISHUB_USERNAME");
                if (self.aishub_username != null) {
                    self.source = .aishub;
                    std.debug.print("AIS: using AISHub (global)\n", .{});
                } else {
                    self.source = .digitraffic;
                    std.debug.print("AIS: using Digitraffic (Finland). Set AISHUB_USERNAME for global coverage.\n", .{});
                }
                self.shutdown.store(false, .release);
                self.worker = std.Thread.spawn(.{}, workerLoop, .{self}) catch null;
            }
        }
    }

    pub fn update(self: *AisOverlay, _: *const overlay.FrameContext) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.has_pending) {
            @memcpy(self.vessels[0..self.pending_count], self.pending_vessels[0..self.pending_count]);
            self.count = self.pending_count;
            self.has_pending = false;
        }
    }

    pub fn drawWorld(self: *AisOverlay, _: *const overlay.FrameContext) void {
        for (self.vessels[0..self.count]) |v| {
            const pos = rl.vec2(v.x, v.y);
            // Draw a small diamond shape for ships
            const s: f32 = 0.08;
            rl.drawTriangle(
                rl.vec2(v.x, v.y - s),
                rl.vec2(v.x - s * 0.6, v.y + s * 0.5),
                rl.vec2(v.x + s * 0.6, v.y + s * 0.5),
                DOT_COLOR,
            );

            // Course indicator
            if (v.course > 0 and v.speed > 0.5) {
                const rad = (v.course - 90.0) * std.math.pi / 180.0;
                const len: f32 = 0.15;
                const end = rl.vec2(v.x + @cos(rad) * len, v.y + @sin(rad) * len);
                rl.drawLineEx(pos, end, 0.02, HEADING_COLOR);
            }
        }
    }

    pub fn drawScreen(self: *AisOverlay, fctx: *const overlay.FrameContext) void {
        const cam = fctx.cam;
        for (self.vessels[0..self.count]) |v| {
            if (v.name_len == 0) continue;
            if (cam.zoom < 3.0) continue;

            const screen = rl.getWorldToScreen2D(rl.vec2(v.x, v.y), cam);
            if (screen.x < 0 or screen.y < 0) continue;
            if (screen.x > @as(f32, @floatFromInt(fctx.sw)) or screen.y > @as(f32, @floatFromInt(fctx.sh))) continue;

            var label_buf: [21:0]u8 = undefined;
            @memcpy(label_buf[0..v.name_len], v.name[0..v.name_len]);
            label_buf[v.name_len] = 0;
            rl.drawTextEx(fctx.font, &label_buf, rl.vec2(screen.x + 5, screen.y - 5), 9, 1.0, LABEL_COLOR);
        }
    }

    pub fn statusText(_: *const AisOverlay, buf: []u8) usize {
        const tag = "AIS";
        if (buf.len < tag.len) return 0;
        @memcpy(buf[0..tag.len], tag);
        return tag.len;
    }

    fn workerLoop(self: *AisOverlay) void {
        var client = std.http.Client{ .allocator = std.heap.page_allocator };
        defer client.deinit();

        while (!self.shutdown.load(.acquire)) {
            switch (self.source) {
                .aishub => self.fetchAishub(&client),
                .digitraffic => self.fetchDigitraffic(&client),
            }
            var slept: u64 = 0;
            while (slept < POLL_INTERVAL_NS and !self.shutdown.load(.acquire)) {
                std.time.sleep(500 * std.time.ns_per_ms);
                slept += 500 * std.time.ns_per_ms;
            }
        }
    }

    // --- AISHub: global coverage, requires free account ---
    // Response: [ {"ERROR":false}, [ {vessel}, {vessel}, ... ] ]
    // Vessel: {"MMSI":..., "LONGITUDE":..., "LATITUDE":..., "COG":..., "SOG":..., "NAME":"...", ...}

    fn fetchAishub(self: *AisOverlay, client: *std.http.Client) void {
        const username = self.aishub_username orelse return;

        // Build URL: https://data.aishub.net/ws.php?username=XXX&format=1&output=json&compress=0
        var url_buf: [256]u8 = undefined;
        const url_slice = std.fmt.bufPrint(&url_buf, "https://data.aishub.net/ws.php?username={s}&format=1&output=json&compress=0", .{username}) catch return;
        // Null-terminate for Uri.parse
        url_buf[url_slice.len] = 0;

        const uri = std.Uri.parse(url_slice) catch return;

        const body = httpGet(client, uri) orelse {
            self.last_fetch_status = .err;
            return;
        };
        defer body.deinit();

        self.parseAishub(body.items);
    }

    fn parseAishub(self: *AisOverlay, body: []const u8) void {
        var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch {
            self.last_fetch_status = .err;
            return;
        };
        defer parsed.deinit();

        // Response is a 2-element array: [ {error_status}, [vessels...] ]
        if (parsed.value != .array or parsed.value.array.items.len < 2) {
            self.last_fetch_status = .err;
            return;
        }
        const vessels_val = parsed.value.array.items[1];
        if (vessels_val != .array) {
            self.last_fetch_status = .err;
            return;
        }

        var tmp: [MAX_VESSELS]Vessel = undefined;
        var count: usize = 0;

        for (vessels_val.array.items) |item| {
            if (count >= MAX_VESSELS) break;
            if (item != .object) continue;
            const obj = item.object;

            const lat_val = obj.get("LATITUDE") orelse continue;
            const lon_val = obj.get("LONGITUDE") orelse continue;

            const lat: f32 = @floatCast(jsonFloat(lat_val));
            const lon: f32 = @floatCast(jsonFloat(lon_val));
            if (lat == 0 and lon == 0) continue;

            const world_pos = worldmap_mod.latLonToWorld(lat, lon);
            var vessel = Vessel{
                .x = world_pos[0],
                .y = world_pos[1],
            };

            if (obj.get("NAME")) |name_val| {
                if (name_val == .string) {
                    const name = std.mem.trimRight(u8, name_val.string, " ");
                    const copy_len = @min(name.len, 20);
                    @memcpy(vessel.name[0..copy_len], name[0..copy_len]);
                    vessel.name_len = @intCast(copy_len);
                }
            }
            if (obj.get("COG")) |c| vessel.course = @floatCast(jsonFloat(c));
            if (obj.get("SOG")) |s| vessel.speed = @floatCast(jsonFloat(s));
            if (obj.get("MMSI")) |m| {
                if (m == .integer) vessel.mmsi = @intCast(@max(0, m.integer));
            }

            tmp[count] = vessel;
            count += 1;
        }

        publishVessels(self, &tmp, count);
    }

    // --- Digitraffic: Finland only, no auth required ---
    // Response: GeoJSON FeatureCollection

    fn fetchDigitraffic(self: *AisOverlay, client: *std.http.Client) void {
        const url = "https://meri.digitraffic.fi/api/ais/v1/locations";
        const uri = std.Uri.parse(url) catch return;

        const body = httpGet(client, uri) orelse {
            self.last_fetch_status = .err;
            return;
        };
        defer body.deinit();

        self.parseDigitraffic(body.items);
    }

    fn parseDigitraffic(self: *AisOverlay, body: []const u8) void {
        var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch {
            self.last_fetch_status = .err;
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            self.last_fetch_status = .err;
            return;
        }

        const features_val = root.object.get("features") orelse {
            self.last_fetch_status = .err;
            return;
        };
        if (features_val != .array) {
            self.last_fetch_status = .err;
            return;
        }

        var tmp: [MAX_VESSELS]Vessel = undefined;
        var count: usize = 0;

        for (features_val.array.items) |feat| {
            if (count >= MAX_VESSELS) break;
            if (feat != .object) continue;
            const obj = feat.object;

            const geom = obj.get("geometry") orelse continue;
            if (geom != .object) continue;
            const coords_val = geom.object.get("coordinates") orelse continue;
            if (coords_val != .array) continue;
            const coords = coords_val.array.items;
            if (coords.len < 2) continue;

            const lon: f32 = @floatCast(jsonFloat(coords[0]));
            const lat: f32 = @floatCast(jsonFloat(coords[1]));
            if (lat == 0 and lon == 0) continue;

            const world_pos = worldmap_mod.latLonToWorld(lat, lon);
            var vessel = Vessel{
                .x = world_pos[0],
                .y = world_pos[1],
            };

            if (obj.get("mmsi")) |m| {
                if (m == .integer) vessel.mmsi = @intCast(@max(0, m.integer));
            }

            if (obj.get("properties")) |props_val| {
                if (props_val == .object) {
                    const props = props_val.object;
                    if (props.get("cog")) |c| vessel.course = @floatCast(jsonFloat(c));
                    if (props.get("sog")) |s| vessel.speed = @floatCast(jsonFloat(s));
                    if (props.get("name")) |name_val| {
                        if (name_val == .string) {
                            const name = std.mem.trimRight(u8, name_val.string, " ");
                            const copy_len = @min(name.len, 20);
                            @memcpy(vessel.name[0..copy_len], name[0..copy_len]);
                            vessel.name_len = @intCast(copy_len);
                        }
                    }
                }
            }

            tmp[count] = vessel;
            count += 1;
        }

        publishVessels(self, &tmp, count);
    }

    fn publishVessels(self: *AisOverlay, tmp: *const [MAX_VESSELS]Vessel, count: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        @memcpy(self.pending_vessels[0..count], tmp[0..count]);
        self.pending_count = count;
        self.has_pending = true;
        self.last_fetch_status = .ok;
        std.debug.print("AIS: parsed {d} vessels\n", .{count});
    }
};

/// Shared HTTP GET helper — returns owned body ArrayList or null on error.
fn httpGet(client: *std.http.Client, uri: std.Uri) ?std.ArrayList(u8) {
    var server_header_buf: [4096]u8 = undefined;
    var req = client.open(.GET, uri, .{
        .server_header_buffer = &server_header_buf,
    }) catch return null;
    defer req.deinit();

    req.send() catch return null;
    req.finish() catch return null;
    req.wait() catch return null;

    if (req.response.status != .ok) {
        std.debug.print("AIS: HTTP {d}\n", .{@intFromEnum(req.response.status)});
        return null;
    }

    var body = std.ArrayList(u8).init(std.heap.page_allocator);
    var reader = req.reader();
    reader.readAllArrayList(&body, 16 * 1024 * 1024) catch {
        body.deinit();
        return null;
    };
    return body;
}

fn jsonFloat(val: std.json.Value) f64 {
    return switch (val) {
        .float => val.float,
        .integer => @floatFromInt(val.integer),
        else => 0,
    };
}
