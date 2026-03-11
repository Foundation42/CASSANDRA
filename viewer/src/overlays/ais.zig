const std = @import("std");
const rl = @import("../rl.zig");
const overlay = @import("../overlay.zig");
const worldmap_mod = @import("../worldmap.zig");

const MAX_VESSELS: usize = 8192;
const POLL_INTERVAL_NS: u64 = 60 * std.time.ns_per_s;
const DOT_COLOR = rl.color(80, 160, 255, 200);
const LABEL_COLOR = rl.color(80, 160, 255, 140);
const HEADING_COLOR = rl.color(80, 160, 255, 100);

pub const Vessel = struct {
    x: f32,
    y: f32,
    course: f32 = 0,
    name: [20]u8 = .{0} ** 20,
    name_len: u8 = 0,
    mmsi: u32 = 0,
    speed: f32 = 0,
    ship_type: u8 = 0,
};

const DataSource = enum { aisstream, digitraffic };

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
    aisstream_key: ?[]const u8 = null,

    pub fn enabled(self: *const AisOverlay) bool {
        return self.active;
    }

    pub fn handleToggle(self: *AisOverlay) void {
        if (rl.isKeyPressed(rl.c.KEY_S)) {
            self.active = !self.active;
            if (self.active and self.worker == null) {
                self.aisstream_key = std.posix.getenv("AISSTREAM_API_KEY");
                if (self.aisstream_key != null) {
                    self.source = .aisstream;
                    std.debug.print("AIS: using aisstream.io WebSocket (global)\n", .{});
                } else {
                    self.source = .digitraffic;
                    std.debug.print("AIS: using Digitraffic (Finland). Set AISSTREAM_API_KEY for global.\n", .{});
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
            const s: f32 = 0.08;
            rl.drawTriangle(
                rl.vec2(v.x, v.y - s),
                rl.vec2(v.x - s * 0.6, v.y + s * 0.5),
                rl.vec2(v.x + s * 0.6, v.y + s * 0.5),
                DOT_COLOR,
            );
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
        switch (self.source) {
            .aisstream => self.runAisstream(),
            .digitraffic => self.runDigitraffic(),
        }
    }

    // ---------------------------------------------------------------
    // aisstream.io — global, WebSocket, requires free API key
    // ---------------------------------------------------------------

    fn runAisstream(self: *AisOverlay) void {
        const key = self.aisstream_key orelse return;

        while (!self.shutdown.load(.acquire)) {
            self.aisStreamSession(key);
            // Reconnect after disconnect/error — back off 5s
            if (self.shutdown.load(.acquire)) break;
            std.debug.print("AIS: reconnecting in 5s...\n", .{});
            var slept: u64 = 0;
            while (slept < 5 * std.time.ns_per_s and !self.shutdown.load(.acquire)) {
                std.time.sleep(500 * std.time.ns_per_ms);
                slept += 500 * std.time.ns_per_ms;
            }
        }
    }

    fn aisStreamSession(self: *AisOverlay, key: []const u8) void {
        const host = "stream.aisstream.io";
        const port: u16 = 443;

        // TCP connect
        const tcp = std.net.tcpConnectToHost(std.heap.page_allocator, host, port) catch |err| {
            std.debug.print("AIS: TCP connect failed: {}\n", .{err});
            self.last_fetch_status = .err;
            return;
        };
        defer tcp.close();

        // TLS handshake
        var tls = std.crypto.tls.Client.init(tcp, .{
            .host = .{ .explicit = host },
            .ca = .no_verification, // aisstream.io uses a standard CA; skip for simplicity
        }) catch |err| {
            std.debug.print("AIS: TLS handshake failed: {}\n", .{err});
            self.last_fetch_status = .err;
            return;
        };

        // WebSocket upgrade handshake
        const ws_key = "dGhlIHNhbXBsZSBub25jZQ=="; // fixed nonce, fine for this use
        const upgrade_req = "GET /v0/stream HTTP/1.1\r\n" ++
            "Host: stream.aisstream.io\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "Sec-WebSocket-Key: " ++ ws_key ++ "\r\n" ++
            "\r\n";

        tls.writeAll(tcp, upgrade_req) catch |err| {
            std.debug.print("AIS: WS upgrade write failed: {}\n", .{err});
            self.last_fetch_status = .err;
            return;
        };

        // Read upgrade response (just consume until \r\n\r\n)
        var resp_buf: [2048]u8 = undefined;
        var resp_len: usize = 0;
        while (resp_len < resp_buf.len) {
            const n = tls.read(tcp, resp_buf[resp_len..]) catch |err| {
                std.debug.print("AIS: WS upgrade read failed: {}\n", .{err});
                self.last_fetch_status = .err;
                return;
            };
            if (n == 0) return;
            resp_len += n;
            if (std.mem.indexOf(u8, resp_buf[0..resp_len], "\r\n\r\n")) |_| break;
        }

        // Check for 101 Switching Protocols
        if (!std.mem.startsWith(u8, resp_buf[0..resp_len], "HTTP/1.1 101")) {
            std.debug.print("AIS: WS upgrade rejected: {s}\n", .{resp_buf[0..@min(resp_len, 80)]});
            self.last_fetch_status = .err;
            return;
        }
        std.debug.print("AIS: WebSocket connected\n", .{});

        // Send subscription message
        var sub_buf: [512]u8 = undefined;
        const sub_msg = std.fmt.bufPrint(&sub_buf,
            \\{{"APIKey":"{s}","BoundingBoxes":[[[-90,-180],[90,180]]],"FilterMessageTypes":["PositionReport"]}}
        , .{key}) catch return;

        wsWriteText(&tls, tcp, sub_msg) catch |err| {
            std.debug.print("AIS: WS subscribe write failed: {}\n", .{err});
            self.last_fetch_status = .err;
            return;
        };
        std.debug.print("AIS: subscribed to global PositionReport\n", .{});

        // Accumulate vessels, publish every ~2s
        var vessel_map = std.AutoHashMap(u32, Vessel).init(std.heap.page_allocator);
        defer vessel_map.deinit();
        var last_publish = std.time.milliTimestamp();

        // Read WebSocket messages
        var frame_buf: [65536]u8 = undefined;
        while (!self.shutdown.load(.acquire)) {
            const msg = wsReadMessage(&tls, tcp, &frame_buf) catch |err| {
                std.debug.print("AIS: WS read error: {}\n", .{err});
                break;
            };
            if (msg.len == 0) break; // connection closed

            // Parse the position report
            self.parseAisStreamMsg(msg, &vessel_map);

            // Publish snapshot every 2 seconds
            const now = std.time.milliTimestamp();
            if (now - last_publish > 2000) {
                self.publishFromMap(&vessel_map);
                last_publish = now;
            }
        }

        // Final publish
        if (vessel_map.count() > 0) {
            self.publishFromMap(&vessel_map);
        }
    }

    fn parseAisStreamMsg(self: *AisOverlay, msg: []const u8, vessel_map: *std.AutoHashMap(u32, Vessel)) void {
        _ = self;
        var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, msg, .{}) catch return;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return;

        // Extract metadata for ship name + MMSI
        const meta = root.object.get("MetaData") orelse return;
        if (meta != .object) return;
        const mmsi_val = meta.object.get("MMSI") orelse return;
        const mmsi: u32 = switch (mmsi_val) {
            .integer => @intCast(@max(0, mmsi_val.integer)),
            else => return,
        };

        const lat: f32 = @floatCast(jsonFloat(meta.object.get("latitude") orelse return));
        const lon: f32 = @floatCast(jsonFloat(meta.object.get("longitude") orelse return));
        if (lat == 0 and lon == 0) return;

        const world_pos = worldmap_mod.latLonToWorld(lat, lon);
        var vessel = Vessel{
            .x = world_pos[0],
            .y = world_pos[1],
            .mmsi = mmsi,
        };

        // Ship name from metadata
        if (meta.object.get("ShipName")) |name_val| {
            if (name_val == .string) {
                const name = std.mem.trimRight(u8, name_val.string, " ");
                const copy_len = @min(name.len, 20);
                @memcpy(vessel.name[0..copy_len], name[0..copy_len]);
                vessel.name_len = @intCast(copy_len);
            }
        }

        // COG/SOG from Message.PositionReport
        if (root.object.get("Message")) |msg_obj| {
            if (msg_obj == .object) {
                if (msg_obj.object.get("PositionReport")) |pr| {
                    if (pr == .object) {
                        if (pr.object.get("Cog")) |c| vessel.course = @floatCast(jsonFloat(c));
                        if (pr.object.get("Sog")) |s| vessel.speed = @floatCast(jsonFloat(s));
                    }
                }
            }
        }

        vessel_map.put(mmsi, vessel) catch {};
    }

    fn publishFromMap(self: *AisOverlay, vessel_map: *std.AutoHashMap(u32, Vessel)) void {
        var tmp: [MAX_VESSELS]Vessel = undefined;
        var count: usize = 0;
        var it = vessel_map.valueIterator();
        while (it.next()) |v| {
            if (count >= MAX_VESSELS) break;
            tmp[count] = v.*;
            count += 1;
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        @memcpy(self.pending_vessels[0..count], tmp[0..count]);
        self.pending_count = count;
        self.has_pending = true;
        self.last_fetch_status = .ok;
    }

    // ---------------------------------------------------------------
    // Digitraffic — Finland only, HTTP polling, no auth
    // ---------------------------------------------------------------

    fn runDigitraffic(self: *AisOverlay) void {
        var client = std.http.Client{ .allocator = std.heap.page_allocator };
        defer client.deinit();

        while (!self.shutdown.load(.acquire)) {
            self.fetchDigitraffic(&client);
            var slept: u64 = 0;
            while (slept < POLL_INTERVAL_NS and !self.shutdown.load(.acquire)) {
                std.time.sleep(500 * std.time.ns_per_ms);
                slept += 500 * std.time.ns_per_ms;
            }
        }
    }

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
        if (root != .object) { self.last_fetch_status = .err; return; }
        const features_val = root.object.get("features") orelse { self.last_fetch_status = .err; return; };
        if (features_val != .array) { self.last_fetch_status = .err; return; }

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
            var vessel = Vessel{ .x = world_pos[0], .y = world_pos[1] };

            if (obj.get("mmsi")) |m| {
                if (m == .integer) vessel.mmsi = @intCast(@max(0, m.integer));
            }
            if (obj.get("properties")) |pv| {
                if (pv == .object) {
                    const p = pv.object;
                    if (p.get("cog")) |c| vessel.course = @floatCast(jsonFloat(c));
                    if (p.get("sog")) |s| vessel.speed = @floatCast(jsonFloat(s));
                    if (p.get("name")) |nv| {
                        if (nv == .string) {
                            const nm = std.mem.trimRight(u8, nv.string, " ");
                            const cl = @min(nm.len, 20);
                            @memcpy(vessel.name[0..cl], nm[0..cl]);
                            vessel.name_len = @intCast(cl);
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
        std.debug.print("AIS: parsed {d} vessels (Digitraffic)\n", .{count});
    }
};

// ---------------------------------------------------------------
// Minimal WebSocket client helpers (RFC 6455)
// ---------------------------------------------------------------

const TlsClient = std.crypto.tls.Client;

/// Write a masked WebSocket text frame.
fn wsWriteText(tls: *TlsClient, tcp: std.net.Stream, payload: []const u8) !void {
    // Header: FIN=1, opcode=1 (text), MASK=1
    var header: [14]u8 = undefined;
    header[0] = 0x81; // FIN + text
    var hdr_len: usize = 2;

    if (payload.len < 126) {
        header[1] = @as(u8, @intCast(payload.len)) | 0x80; // masked
    } else if (payload.len <= 65535) {
        header[1] = 126 | 0x80;
        header[2] = @intCast((payload.len >> 8) & 0xFF);
        header[3] = @intCast(payload.len & 0xFF);
        hdr_len = 4;
    } else {
        // 8-byte extended length
        header[1] = 127 | 0x80;
        const len64: u64 = @intCast(payload.len);
        inline for (0..8) |i| {
            header[2 + i] = @intCast((len64 >> @intCast(56 - i * 8)) & 0xFF);
        }
        hdr_len = 10;
    }

    // Masking key (RFC 6455 requires client frames to be masked)
    const mask = [4]u8{ 0x12, 0x34, 0x56, 0x78 }; // fixed mask, fine for this use
    @memcpy(header[hdr_len..][0..4], &mask);
    hdr_len += 4;

    try tls.writeAll(tcp, header[0..hdr_len]);

    // Write masked payload in chunks
    var masked_buf: [4096]u8 = undefined;
    var offset: usize = 0;
    while (offset < payload.len) {
        const chunk = @min(payload.len - offset, masked_buf.len);
        for (0..chunk) |i| {
            masked_buf[i] = payload[offset + i] ^ mask[(offset + i) % 4];
        }
        try tls.writeAll(tcp, masked_buf[0..chunk]);
        offset += chunk;
    }
}

/// Read a single WebSocket message. Returns the payload slice within frame_buf.
/// Returns empty slice on connection close.
fn wsReadMessage(tls: *TlsClient, tcp: std.net.Stream, frame_buf: *[65536]u8) ![]const u8 {
    // Read 2-byte header
    var hdr: [2]u8 = undefined;
    if (try readExact(tls, tcp, &hdr) != 2) return frame_buf[0..0];

    const fin = (hdr[0] & 0x80) != 0;
    _ = fin;
    const opcode = hdr[0] & 0x0F;
    const masked = (hdr[1] & 0x80) != 0;
    var payload_len: u64 = hdr[1] & 0x7F;

    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        if (try readExact(tls, tcp, &ext) != 2) return frame_buf[0..0];
        payload_len = (@as(u64, ext[0]) << 8) | @as(u64, ext[1]);
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        if (try readExact(tls, tcp, &ext) != 8) return frame_buf[0..0];
        payload_len = 0;
        inline for (0..8) |i| {
            payload_len |= @as(u64, ext[i]) << @intCast(56 - i * 8);
        }
    }

    var mask_key: [4]u8 = undefined;
    if (masked) {
        if (try readExact(tls, tcp, &mask_key) != 4) return frame_buf[0..0];
    }

    // Connection close
    if (opcode == 0x8) return frame_buf[0..0];

    // Ping — respond with pong
    if (opcode == 0x9) {
        const plen: usize = @intCast(@min(payload_len, frame_buf.len));
        if (try readExact(tls, tcp, frame_buf[0..plen]) != plen) return frame_buf[0..0];
        // Send pong (opcode 0xA)
        var pong_hdr: [6]u8 = undefined;
        pong_hdr[0] = 0x8A; // FIN + pong
        pong_hdr[1] = @as(u8, @intCast(plen)) | 0x80;
        const pmask = [4]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
        @memcpy(pong_hdr[2..6], &pmask);
        tls.writeAll(tcp, pong_hdr[0..(2 + 4)]) catch {};
        // Write masked pong payload
        for (0..plen) |i| frame_buf[i] ^= pmask[i % 4];
        tls.writeAll(tcp, frame_buf[0..plen]) catch {};
        // Recurse to get next real message
        return wsReadMessage(tls, tcp, frame_buf);
    }

    // Read payload
    const len: usize = @intCast(@min(payload_len, frame_buf.len));
    if (try readExact(tls, tcp, frame_buf[0..len]) != len) return frame_buf[0..0];

    // Unmask if needed (server frames shouldn't be masked, but handle it)
    if (masked) {
        for (0..len) |i| {
            frame_buf[i] ^= mask_key[i % 4];
        }
    }

    return frame_buf[0..len];
}

fn readExact(tls: *TlsClient, tcp: std.net.Stream, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try tls.read(tcp, buf[total..]);
        if (n == 0) return total;
        total += n;
    }
    return total;
}

// ---------------------------------------------------------------
// HTTP GET helper for Digitraffic polling
// ---------------------------------------------------------------

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
