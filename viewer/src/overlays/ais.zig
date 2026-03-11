const std = @import("std");
const rl = @import("../rl.zig");
const overlay = @import("../overlay.zig");
const worldmap_mod = @import("../worldmap.zig");
const photo_mod = @import("../photo.zig");
const overlay_db_mod = @import("../overlay_db.zig");

const MAX_VESSELS: usize = 32768;
const MAX_LABELS: usize = 200;
const POLL_INTERVAL_NS: u64 = 60 * std.time.ns_per_s;
const HEADING_ALPHA: u8 = 100;

pub const Vessel = struct {
    x: f32,
    y: f32,
    course: f32 = 0,
    name: [20]u8 = .{0} ** 20,
    name_len: u8 = 0,
    mmsi: u32 = 0,
    imo: u32 = 0,
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
    selected_mmsi: u32 = 0, // stable selection across data swaps
    overlay_db: ?*overlay_db_mod.OverlayDb = null,

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
            const col = shipTypeColor(v.ship_type);
            const s: f32 = 0.06;

            // Rotate triangle to point along course (0° = north, CW)
            const rad = v.course * std.math.pi / 180.0;
            const cos_r = @cos(rad);
            const sin_r = @sin(rad);

            // Triangle verts in local space (tip forward = +Y up = north)
            // tip: (0, -s), left: (-s*0.6, +s*0.5), right: (+s*0.6, +s*0.5)
            // Rotate by course: x' = x*cos - y*sin, y' = x*sin + y*cos
            const tip = rl.vec2(v.x + (0) * cos_r - (-s) * sin_r, v.y + (0) * sin_r + (-s) * cos_r);
            const left = rl.vec2(v.x + (-s * 0.6) * cos_r - (s * 0.5) * sin_r, v.y + (-s * 0.6) * sin_r + (s * 0.5) * cos_r);
            const right = rl.vec2(v.x + (s * 0.6) * cos_r - (s * 0.5) * sin_r, v.y + (s * 0.6) * sin_r + (s * 0.5) * cos_r);

            rl.drawTriangle(tip, left, right, col);
        }
    }

    pub fn drawScreen(self: *AisOverlay, fctx: *const overlay.FrameContext) void {
        const cam = fctx.cam;
        const sw_f: f32 = @floatFromInt(fctx.sw);
        const sh_f: f32 = @floatFromInt(fctx.sh);
        const margin: f32 = 50;

        const budget = vesselLabelBudget(cam.zoom);
        const imp_thresh = vesselLabelThreshold(cam.zoom);
        if (budget == 0) return;

        // Pass 1: collect top-K labels by importance (viewport-culled)
        const LabelSlot = struct { idx: u16, importance: f32, screen_x: f32, screen_y: f32 };
        var slots: [MAX_LABELS]LabelSlot = undefined;
        var n_slots: usize = 0;
        var min_imp: f32 = 0;
        var min_idx: usize = 0;

        for (self.vessels[0..self.count], 0..) |v, i| {
            if (v.name_len == 0) continue;
            const screen = rl.getWorldToScreen2D(rl.vec2(v.x, v.y), cam);
            if (screen.x < -margin or screen.x > sw_f + margin or screen.y < -margin or screen.y > sh_f + margin) continue;

            const imp = vesselImportance(v, cam.zoom);
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
        const zoom_scale = 1.0 + std.math.clamp((cam.zoom - 3.0) * 0.08, 0.0, 1.0);
        const font_size: f32 = 9.0 * zoom_scale;

        for (slots[0..n_slots]) |slot| {
            const above = slot.importance - threshold;
            const range: f32 = 0.5;
            const alpha = std.math.clamp(above / (range * 0.3), 0.15, 1.0);
            const v = self.vessels[slot.idx];
            const base = shipTypeColor(v.ship_type);
            const a: u8 = @intFromFloat(alpha * @as(f32, @floatFromInt(base.a)));
            const col = rl.colorAlpha(base, a);
            var label_buf: [21:0]u8 = undefined;
            @memcpy(label_buf[0..v.name_len], v.name[0..v.name_len]);
            label_buf[v.name_len] = 0;
            rl.drawTextEx(fctx.font, &label_buf, rl.vec2(slot.screen_x + 5, slot.screen_y - 5), font_size, 1.0, col);
        }
    }

    pub fn statusText(_: *const AisOverlay, buf: []u8) usize {
        const tag = "AIS";
        if (buf.len < tag.len) return 0;
        @memcpy(buf[0..tag.len], tag);
        return tag.len;
    }

    pub fn hitTest(self: *AisOverlay, world_pos: rl.Vector2, max_dist_sq: f32) ?overlay.OverlayItemHit {
        self.selected_mmsi = 0; // reset stable selection on new click
        var best_dist: f32 = max_dist_sq;
        var best_idx: ?u16 = null;
        for (self.vessels[0..self.count], 0..) |v, i| {
            const dx = world_pos.x - v.x;
            const dy = world_pos.y - v.y;
            const d2 = dx * dx + dy * dy;
            if (d2 < best_dist) {
                best_dist = d2;
                best_idx = @intCast(i);
            }
        }
        if (best_idx) |idx| {
            return .{ .item_idx = idx, .dist_sq = best_dist };
        }
        return null;
    }

    pub fn drawDetail(self: *AisOverlay, fctx: *const overlay.FrameContext, item_idx: u16) void {
        // Capture MMSI on first call, then re-resolve by MMSI each frame
        // so the panel stays stable across data swaps.
        if (self.selected_mmsi == 0 and item_idx < self.count) {
            self.selected_mmsi = self.vessels[item_idx].mmsi;
        }
        const v = blk: {
            if (self.selected_mmsi != 0) {
                for (self.vessels[0..self.count]) |vessel| {
                    if (vessel.mmsi == self.selected_mmsi) break :blk vessel;
                }
                // Vessel was pruned — don't fall back to a random one
                return;
            }
            if (item_idx >= self.count) return;
            break :blk self.vessels[item_idx];
        };
        const font = fctx.font;
        const photo_cache = fctx.photo_cache;

        const panel_w: f32 = 260;
        const panel_x: f32 = @as(f32, @floatFromInt(fctx.sw)) - panel_w - 10;
        const panel_y: f32 = 50;
        const pad: f32 = 12;
        const sz: f32 = 14;

        // Request photo by MMSI + IMO
        const photo_key = photo_mod.PhotoKey{ .vessel = .{ .mmsi = v.mmsi, .imo = v.imo } };
        photo_cache.requestPhoto(photo_key);

        // Compute content height
        var content_h: f32 = 0;
        content_h += 24; // title
        content_h += 18; // mmsi line
        content_h += (sz + 4) * 4; // type, speed, course, pos

        // Photo section height
        var photo_tex: ?rl.c.Texture2D = null;
        var photo_h: f32 = 0;
        const photo_state = photo_cache.getState(photo_key);
        if (photo_state) |state| {
            switch (state) {
                .pending => {
                    photo_h = 20;
                },
                .loaded => |tex| {
                    photo_tex = tex;
                    const max_w = panel_w - pad * 2;
                    const scale = max_w / @as(f32, @floatFromInt(tex.width));
                    photo_h = @as(f32, @floatFromInt(tex.height)) * scale + 8;
                },
                .not_found => {},
            }
        }

        const panel_h = content_h + photo_h + pad * 2;

        rl.drawRectangleRounded(.{
            .x = panel_x,
            .y = panel_y,
            .width = panel_w,
            .height = panel_h,
        }, 0.05, 8, rl.color(10, 12, 18, 220));

        const x = panel_x + pad;
        var y: f32 = panel_y + pad;

        // Title: vessel name in ship type color
        const col = shipTypeColor(v.ship_type);
        if (v.name_len > 0) {
            var name_buf: [21:0]u8 = undefined;
            @memcpy(name_buf[0..v.name_len], v.name[0..v.name_len]);
            name_buf[v.name_len] = 0;
            rl.drawTextEx(font, &name_buf, rl.vec2(x, y), 18, 1.0, col);
        } else {
            rl.drawTextEx(font, "UNKNOWN VESSEL", rl.vec2(x, y), 18, 1.0, col);
        }
        y += 24;

        var buf: [64]u8 = undefined;

        // MMSI
        printZ(&buf, "MMSI: {d}", .{v.mmsi});
        rl.drawTextEx(font, @ptrCast(&buf), rl.vec2(x, y), 12, 1.0, rl.color(120, 140, 160, 200));
        y += 18;

        // Ship type
        const type_name = shipTypeName(v.ship_type);
        printZ(&buf, "Type: {s}", .{type_name});
        rl.drawTextEx(font, @ptrCast(&buf), rl.vec2(x, y), sz, 1.0, rl.color(180, 190, 200, 220));
        y += sz + 4;

        // Speed
        printZ(&buf, "Speed: {d:.1} kt", .{v.speed});
        rl.drawTextEx(font, @ptrCast(&buf), rl.vec2(x, y), sz, 1.0, rl.color(180, 190, 200, 220));
        y += sz + 4;

        // Course
        printZ(&buf, "Course: {d:.0}\xc2\xb0", .{v.course});
        rl.drawTextEx(font, @ptrCast(&buf), rl.vec2(x, y), sz, 1.0, rl.color(180, 190, 200, 220));
        y += sz + 4;

        // Lat/Lon
        const ll = worldmap_mod.worldToLatLon(v.x, v.y);
        printZ(&buf, "Pos: {d:.3}, {d:.3}", .{ ll[0], ll[1] });
        rl.drawTextEx(font, @ptrCast(&buf), rl.vec2(x, y), sz, 1.0, rl.color(180, 190, 200, 220));
        y += sz + 4;

        // Photo
        if (photo_tex) |tex| {
            y += 4;
            const max_w = panel_w - pad * 2;
            const scale = max_w / @as(f32, @floatFromInt(tex.width));
            const draw_h = @as(f32, @floatFromInt(tex.height)) * scale;
            rl.c.DrawTexturePro(
                tex,
                .{ .x = 0, .y = 0, .width = @floatFromInt(tex.width), .height = @floatFromInt(tex.height) },
                .{ .x = x, .y = y, .width = max_w, .height = draw_h },
                .{ .x = 0, .y = 0 },
                0,
                rl.c.WHITE,
            );
        } else if (photo_state) |state| {
            switch (state) {
                .pending => {
                    y += 4;
                    rl.drawTextEx(font, "Loading photo...", rl.vec2(x, y), 11, 1.0, rl.color(100, 110, 120, 180));
                },
                else => {},
            }
        }
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
            \\{{"APIKey":"{s}","BoundingBoxes":[[[-90,-180],[90,180]]],"FilterMessageTypes":["PositionReport","ShipStaticData"]}}
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

        // Seed HashMap from DB-loaded vessels (already in self.vessels from startup)
        {
            self.mutex.lock();
            const preloaded = self.count;
            self.mutex.unlock();
            for (self.vessels[0..preloaded]) |v| {
                if (v.mmsi > 0) vessel_map.put(v.mmsi, v) catch {};
            }
            if (preloaded > 0) std.debug.print("AIS: seeded HashMap with {d} vessels from DB\n", .{preloaded});
        }

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
        var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, msg, .{}) catch return;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return;

        const meta = root.object.get("MetaData") orelse return;
        if (meta != .object) return;
        const mmsi_val = meta.object.get("MMSI") orelse return;
        const mmsi: u32 = switch (mmsi_val) {
            .integer => @intCast(@max(0, mmsi_val.integer)),
            else => return,
        };

        const msg_obj = root.object.get("Message") orelse return;
        if (msg_obj != .object) return;

        // ShipStaticData message (type 5/24): update ship_type and IMO on existing vessel
        if (msg_obj.object.get("ShipStaticData")) |ssd| {
            if (ssd == .object) {
                const st = jsonInt(ssd.object.get("Type"));
                const imo = jsonInt(ssd.object.get("ImoNumber"));
                if (st > 0 or imo > 0) {
                    if (vessel_map.getPtr(mmsi)) |existing| {
                        if (st > 0) existing.ship_type = @intCast(@min(st, 255));
                        if (imo > 0) existing.imo = imo;
                    }
                }
            }
            return;
        }

        // PositionReport: need lat/lon
        const lat: f32 = @floatCast(jsonFloat(meta.object.get("latitude") orelse return));
        const lon: f32 = @floatCast(jsonFloat(meta.object.get("longitude") orelse return));
        if (lat == 0 and lon == 0) return;

        const world_pos = worldmap_mod.latLonToWorld(lat, lon);

        // Start from existing vessel data (preserves ship_type from earlier static msg)
        var vessel = if (vessel_map.get(mmsi)) |existing| existing else Vessel{ .x = world_pos[0], .y = world_pos[1], .mmsi = mmsi };
        vessel.x = world_pos[0];
        vessel.y = world_pos[1];

        // Ship name from metadata
        if (meta.object.get("ShipName")) |name_val| {
            if (name_val == .string) {
                const name = std.mem.trimRight(u8, name_val.string, " ");
                const copy_len = @min(name.len, 20);
                @memcpy(vessel.name[0..copy_len], name[0..copy_len]);
                vessel.name_len = @intCast(copy_len);
            }
        }

        // COG/SOG from PositionReport
        if (msg_obj.object.get("PositionReport")) |pr| {
            if (pr == .object) {
                if (pr.object.get("Cog")) |c| vessel.course = @floatCast(jsonFloat(c));
                if (pr.object.get("Sog")) |s| vessel.speed = @floatCast(jsonFloat(s));
            }
        }

        vessel_map.put(mmsi, vessel) catch {};

        // Persist to DB
        if (self.overlay_db) |db| db.upsertVessel(vessel);
    }

    fn publishFromMap(self: *AisOverlay, vessel_map: *std.AutoHashMap(u32, Vessel)) void {
        var tmp: [MAX_VESSELS]Vessel = undefined;
        var count: usize = 0;
        var typed: usize = 0;
        var it = vessel_map.valueIterator();
        while (it.next()) |v| {
            if (count >= MAX_VESSELS) break;
            tmp[count] = v.*;
            if (v.ship_type > 0) typed += 1;
            count += 1;
        }

        // Sort by MMSI so array indices are stable across updates (preserves selection)
        std.mem.sort(Vessel, tmp[0..count], {}, struct {
            fn cmp(_: void, a: Vessel, b: Vessel) bool {
                return a.mmsi < b.mmsi;
            }
        }.cmp);

        std.debug.print("AIS: publishing {d} vessels ({d} with ship_type)\n", .{ count, typed });

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
                    if (p.get("shipType")) |st| {
                        if (st == .integer) vessel.ship_type = @intCast(@max(0, @min(255, st.integer)));
                    }
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

        std.mem.sort(Vessel, tmp[0..count], {}, struct {
            fn cmp(_: void, a: Vessel, b: Vessel) bool {
                return a.mmsi < b.mmsi;
            }
        }.cmp);

        self.mutex.lock();
        defer self.mutex.unlock();
        @memcpy(self.pending_vessels[0..count], tmp[0..count]);
        self.pending_count = count;
        self.has_pending = true;
        self.last_fetch_status = .ok;
        std.debug.print("AIS: parsed {d} vessels (Digitraffic)\n", .{count});
    }
};

/// Ship type color (MarineTraffic convention, ITU AIS type codes):
///   70-79  Cargo       green
///   80-89  Tanker      red
///   60-69  Passenger   blue
///   30-39  Fishing     orange
///   50-59  Special     purple  (tugs, pilots, SAR, etc.)
///   40-49  High-speed  cyan
///   35-39  Military    gray    (overlap with fishing range; 35 = military in practice)
///   other  Unknown     white
fn shipTypeColor(ship_type: u8) rl.Color {
    return switch (ship_type) {
        70...79 => rl.color(80, 200, 80, 200), // cargo — green
        80...89 => rl.color(220, 60, 60, 200), // tanker — red
        60...69 => rl.color(80, 130, 255, 200), // passenger — blue
        30...39 => rl.color(255, 160, 40, 200), // fishing — orange
        50...59 => rl.color(180, 100, 255, 200), // special craft — purple
        40...49 => rl.color(0, 220, 220, 200), // high-speed craft — cyan
        else => rl.color(160, 180, 200, 180), // unknown — muted white
    };
}

/// Human-readable ship type name from AIS type code.
fn shipTypeName(ship_type: u8) []const u8 {
    return switch (ship_type) {
        70...79 => "Cargo",
        80...89 => "Tanker",
        60...69 => "Passenger",
        30...39 => "Fishing",
        50...59 => "Special Craft",
        40...49 => "High-Speed Craft",
        else => "Unknown",
    };
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

/// Vessel importance: speed-based (fast movers more visible) + zoom reveal.
fn vesselImportance(v: Vessel, zoom: f32) f32 {
    const spd_norm = std.math.clamp(v.speed / 15.0, 0.0, 1.0); // 0-15 m/s (~30 knots)
    const zoom_reveal = std.math.clamp((zoom - 40.0) / 100.0, 0.0, 1.0);
    return @max(spd_norm, zoom_reveal);
}

/// Label budget: 0 below zoom 30, ramps to MAX_LABELS at deep zoom.
fn vesselLabelBudget(zoom: f32) usize {
    if (zoom < 30.0) return 0;
    const t = std.math.clamp((zoom - 30.0) / 60.0, 0.0, 1.0);
    const t2 = std.math.clamp((zoom - 80.0) / 200.0, 0.0, 1.0);
    return @intFromFloat(6.0 + 44.0 * t + @as(f32, MAX_LABELS - 50) * t2);
}

/// Threshold: stricter when zoomed out, relaxes as you zoom in.
fn vesselLabelThreshold(zoom: f32) f32 {
    const t = std.math.clamp((zoom - 30.0) / 100.0, 0.0, 1.0);
    return 0.5 - 0.5 * t;
}

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

fn jsonInt(val: ?std.json.Value) u32 {
    const v = val orelse return 0;
    return switch (v) {
        .integer => @intCast(@max(0, v.integer)),
        .float => @intFromFloat(@max(0.0, v.float)),
        else => 0,
    };
}
