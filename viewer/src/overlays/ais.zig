const std = @import("std");
const rl = @import("../rl.zig");
const overlay = @import("../overlay.zig");
const worldmap_mod = @import("../worldmap.zig");

const MAX_VESSELS: usize = 8192;
const POLL_INTERVAL_NS: u64 = 60 * std.time.ns_per_s; // AIS data changes slowly
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

    pub fn enabled(self: *const AisOverlay) bool {
        return self.active;
    }

    pub fn handleToggle(self: *AisOverlay) void {
        if (rl.isKeyPressed(rl.c.KEY_S)) {
            self.active = !self.active;
            if (self.active and self.worker == null) {
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
            self.fetchAndParse(&client);
            var slept: u64 = 0;
            while (slept < POLL_INTERVAL_NS and !self.shutdown.load(.acquire)) {
                std.time.sleep(500 * std.time.ns_per_ms);
                slept += 500 * std.time.ns_per_ms;
            }
        }
    }

    fn fetchAndParse(self: *AisOverlay, client: *std.http.Client) void {
        // Finnish Transport Agency Digitraffic AIS API — free, no key required.
        // Returns latest vessel locations as GeoJSON FeatureCollection.
        const url = "https://meri.digitraffic.fi/api/ais/v1/locations";
        const uri = std.Uri.parse(url) catch return;

        var server_header_buf: [4096]u8 = undefined;
        var req = client.open(.GET, uri, .{
            .server_header_buffer = &server_header_buf,
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
            std.debug.print("AIS: HTTP {d}\n", .{@intFromEnum(req.response.status)});
            return;
        }

        var body = std.ArrayList(u8).init(std.heap.page_allocator);
        defer body.deinit();
        var reader = req.reader();
        reader.readAllArrayList(&body, 16 * 1024 * 1024) catch {
            self.last_fetch_status = .err;
            return;
        };

        self.parseVessels(body.items);
    }

    fn parseVessels(self: *AisOverlay, body: []const u8) void {
        // Digitraffic GeoJSON FeatureCollection:
        // { "type":"FeatureCollection", "features": [
        //   { "mmsi": 123, "geometry": {"type":"Point","coordinates":[lon,lat]},
        //     "properties": {"sog":10.5, "cog":180.0, "heading":179, ...} }, ...] }
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
        const features = features_val.array.items;

        var tmp: [MAX_VESSELS]Vessel = undefined;
        var count: usize = 0;

        for (features) |feat| {
            if (count >= MAX_VESSELS) break;
            if (feat != .object) continue;
            const obj = feat.object;

            // Extract coordinates from geometry.coordinates = [lon, lat]
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

            // MMSI from top-level
            if (obj.get("mmsi")) |m| {
                if (m == .integer) vessel.mmsi = @intCast(@as(i64, m.integer));
            }

            // Properties: sog, cog, navStat, name
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

        self.mutex.lock();
        defer self.mutex.unlock();
        @memcpy(self.pending_vessels[0..count], tmp[0..count]);
        self.pending_count = count;
        self.has_pending = true;
        self.last_fetch_status = .ok;
        std.debug.print("AIS: parsed {d} vessels\n", .{count});
    }
};

fn jsonFloat(val: std.json.Value) f64 {
    return switch (val) {
        .float => val.float,
        .integer => @floatFromInt(val.integer),
        else => 0,
    };
}
