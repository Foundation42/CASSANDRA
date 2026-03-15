const std = @import("std");
const rl = @import("../rl.zig");
const overlay = @import("../overlay.zig");
const worldmap_mod = @import("../worldmap.zig");

const MAX_CAMERAS: usize = 256;
const POLL_INTERVAL_NS: u64 = 30 * std.time.ns_per_s;
const ICON_RADIUS: f32 = 4.0;

pub const Camera = struct {
    x: f32,
    y: f32,
    name: [64]u8 = .{0} ** 64,
    name_len: u8 = 0,
    url: [512]u8 = .{0} ** 512,
    url_len: u16 = 0,
};

const ImageResponse = struct {
    cam_idx: u16,
    image_bytes: ?[]u8,
};

pub const CameraOverlay = struct {
    active: bool = false,
    cameras: [MAX_CAMERAS]Camera = undefined,
    count: usize = 0,
    loaded: bool = false,

    // Snapshot textures (one per camera, loaded on main thread)
    textures: [MAX_CAMERAS]?rl.c.Texture2D = .{null} ** MAX_CAMERAS,

    // Worker thread for fetching snapshots
    mutex: std.Thread.Mutex = .{},
    worker: ?std.Thread = null,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Response queue: worker → main
    resp_queue: [8]ImageResponse = undefined,
    resp_len: usize = 0,

    // Selected camera for detail view
    selected_cam: ?u16 = null,
    visible: [MAX_CAMERAS]bool = .{false} ** MAX_CAMERAS,

    pub fn enabled(self: *const CameraOverlay) bool {
        return self.active;
    }

    pub fn handleToggle(self: *CameraOverlay) void {
        if (rl.isKeyPressed(rl.c.KEY_W)) {
            self.active = !self.active;
            if (self.active) {
                // Always reload config so changes to cameras.json take effect
                self.loadConfig();
                if (self.worker == null) {
                    self.shutdown.store(false, .release);
                    self.worker = std.Thread.spawn(.{}, workerLoop, .{self}) catch null;
                }
            }
        }
    }

    pub fn update(self: *CameraOverlay, _: *const overlay.FrameContext) void {
        // Drain response queue and create textures on main thread
        self.mutex.lock();
        const n = self.resp_len;
        var resps: [8]ImageResponse = undefined;
        @memcpy(resps[0..n], self.resp_queue[0..n]);
        self.resp_len = 0;
        self.mutex.unlock();

        for (resps[0..n]) |resp| {
            if (resp.image_bytes) |bytes| {
                defer std.heap.page_allocator.free(bytes);
                const fmt = detectFormat(bytes);
                const img = rl.c.LoadImageFromMemory(fmt, bytes.ptr, @intCast(bytes.len));
                if (img.data != null) {
                    // Unload previous texture if any
                    if (self.textures[resp.cam_idx]) |old| {
                        rl.c.UnloadTexture(old);
                    }
                    self.textures[resp.cam_idx] = rl.c.LoadTextureFromImage(img);
                    rl.c.UnloadImage(img);
                }
            }
        }
    }

    pub fn drawWorld(self: *CameraOverlay, fctx: *const overlay.FrameContext) void {
        const cam = fctx.cam;
        const sw_f: f32 = @floatFromInt(fctx.sw);
        const sh_f: f32 = @floatFromInt(fctx.sh);
        const margin: f32 = 20.0;

        for (0..self.count) |i| {
            const c = self.cameras[i];
            const screen = rl.getWorldToScreen2D(rl.vec2(c.x, c.y), cam);
            self.visible[i] = screen.x >= -margin and screen.x <= sw_f + margin and
                screen.y >= -margin and screen.y <= sh_f + margin;
            if (!self.visible[i]) continue;

            const is_selected = if (self.selected_cam) |sel| sel == i else false;

            // Camera icon: small world-space dot (matches ADSB/AIS scale)
            const pos = rl.vec2(c.x, c.y);
            if (is_selected) {
                rl.c.DrawCircleV(pos, 0.15, rl.c.Color{ .r = 255, .g = 200, .b = 50, .a = 60 });
            }
            rl.c.DrawCircleV(pos, 0.06, rl.c.Color{ .r = 255, .g = 200, .b = 50, .a = 200 });
            rl.c.DrawCircleLinesV(pos, 0.08, rl.c.Color{ .r = 255, .g = 200, .b = 50, .a = 120 });

            // Label
            if (cam.zoom > 5.0 or is_selected) {
                const zoom_scale = 1.0 + std.math.clamp((cam.zoom - 2.0) * 0.08, 0.0, 1.0);
                const font_size: f32 = 9.0 * zoom_scale;
                var label_buf: [65:0]u8 = undefined;
                @memcpy(label_buf[0..c.name_len], c.name[0..c.name_len]);
                label_buf[c.name_len] = 0;
                rl.drawTextEx(fctx.font, &label_buf, rl.vec2(screen.x + 8, screen.y - 5), font_size, 1.0, rl.c.Color{ .r = 255, .g = 200, .b = 50, .a = 180 });
            }
        }
    }

    pub fn drawDetail(self: *CameraOverlay, fctx: *const overlay.FrameContext, item_idx: u16) void {
        self.selected_cam = item_idx;
        if (item_idx >= self.count) return;
        const c = self.cameras[item_idx];

        const sw: f32 = @floatFromInt(fctx.sw);
        const sh: f32 = @floatFromInt(fctx.sh);

        // Panel dimensions
        const panel_w: f32 = 320;
        const panel_h: f32 = 260;
        const panel_x: f32 = sw - panel_w - 10;
        const panel_y: f32 = 10;

        // Background
        rl.c.DrawRectangleRounded(
            rl.c.Rectangle{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h },
            0.05,
            8,
            rl.c.Color{ .r = 10, .g = 12, .b = 18, .a = 220 },
        );

        // Camera name
        var name_buf: [65:0]u8 = undefined;
        @memcpy(name_buf[0..c.name_len], c.name[0..c.name_len]);
        name_buf[c.name_len] = 0;
        rl.drawTextEx(fctx.font, &name_buf, rl.vec2(panel_x + 10, panel_y + 8), 12, 1.0, rl.c.Color{ .r = 255, .g = 200, .b = 50, .a = 255 });

        // Snapshot image
        if (self.textures[item_idx]) |tex| {
            const img_y = panel_y + 28;
            const img_w = panel_w - 20;
            const aspect = @as(f32, @floatFromInt(tex.height)) / @as(f32, @floatFromInt(tex.width));
            const img_h = img_w * aspect;
            const clamped_h = @min(img_h, panel_h - 38);
            rl.c.DrawTexturePro(
                tex,
                rl.c.Rectangle{ .x = 0, .y = 0, .width = @floatFromInt(tex.width), .height = @floatFromInt(tex.height) },
                rl.c.Rectangle{ .x = panel_x + 10, .y = img_y, .width = img_w, .height = clamped_h },
                rl.c.Vector2{ .x = 0, .y = 0 },
                0,
                rl.c.WHITE,
            );
            _ = sh;
        } else {
            rl.drawTextEx(fctx.font, "Loading...", rl.vec2(panel_x + 10, panel_y + 40), 10, 1.0, rl.c.Color{ .r = 150, .g = 150, .b = 150, .a = 200 });
        }
    }

    pub fn hitTest(self: *CameraOverlay, world_pos: rl.c.Vector2, max_dist_sq: f32) ?overlay.OverlayItemHit {
        var best_dist: f32 = max_dist_sq;
        var best_idx: ?u16 = null;

        for (0..self.count) |i| {
            if (!self.visible[i]) continue;
            const c = self.cameras[i];
            const dx = world_pos.x - c.x;
            const dy = world_pos.y - c.y;
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

    pub fn statusText(_: *const CameraOverlay, buf: []u8) usize {
        const tag = "CAMS";
        if (buf.len < tag.len) return 0;
        @memcpy(buf[0..tag.len], tag);
        return tag.len;
    }

    // ---------------------------------------------------------------
    // Config loading
    // ---------------------------------------------------------------

    fn loadConfig(self: *CameraOverlay) void {
        const file = std.fs.cwd().openFile("../cameras.json", .{}) catch {
            std.debug.print("CAMS: cameras.json not found\n", .{});
            return;
        };
        defer file.close();

        var buf: [64 * 1024]u8 = undefined;
        const bytes_read = file.readAll(&buf) catch return;
        const json_slice = buf[0..bytes_read];

        var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json_slice, .{}) catch {
            std.debug.print("CAMS: failed to parse cameras.json\n", .{});
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .array) return;

        self.count = 0;
        for (root.array.items) |item| {
            if (self.count >= MAX_CAMERAS) break;
            if (item != .object) continue;

            const name_val = item.object.get("name") orelse continue;
            const lat_val = item.object.get("lat") orelse continue;
            const lon_val = item.object.get("lon") orelse continue;
            const url_val = item.object.get("url") orelse continue;

            if (name_val != .string or url_val != .string) continue;
            const lat = jsonFloat(lat_val) orelse continue;
            const lon = jsonFloat(lon_val) orelse continue;

            var cam_entry: Camera = .{
                .x = undefined,
                .y = undefined,
            };

            const pos = worldmap_mod.latLonToWorld(lat, lon);
            cam_entry.x = pos[0];
            cam_entry.y = pos[1];

            const name_len = @min(name_val.string.len, 64);
            @memcpy(cam_entry.name[0..name_len], name_val.string[0..name_len]);
            cam_entry.name_len = @intCast(name_len);

            const url_len = @min(url_val.string.len, 512);
            @memcpy(cam_entry.url[0..url_len], url_val.string[0..url_len]);
            cam_entry.url_len = @intCast(url_len);

            self.cameras[self.count] = cam_entry;
            self.count += 1;
        }

        self.loaded = true;
        std.debug.print("CAMS: loaded {d} cameras\n", .{self.count});
    }

    // ---------------------------------------------------------------
    // Worker thread: fetches snapshots in a round-robin loop
    // ---------------------------------------------------------------

    fn workerLoop(self: *CameraOverlay) void {
        var client = std.http.Client{ .allocator = std.heap.page_allocator };
        defer client.deinit();

        while (!self.shutdown.load(.acquire)) {
            const n = self.count;
            if (n == 0) {
                std.time.sleep(std.time.ns_per_s);
                continue;
            }

            for (0..n) |i| {
                if (self.shutdown.load(.acquire)) break;

                const cam_entry = self.cameras[i];
                const url_slice = cam_entry.url[0..cam_entry.url_len];

                std.debug.print("CAMS: fetching [{d}/{d}] {s}\n", .{ i + 1, n, cam_entry.name[0..cam_entry.name_len] });

                const image_bytes = fetchSnapshot(&client, url_slice);

                self.mutex.lock();
                if (self.resp_len < 8) {
                    self.resp_queue[self.resp_len] = .{
                        .cam_idx = @intCast(i),
                        .image_bytes = image_bytes,
                    };
                    self.resp_len += 1;
                } else {
                    if (image_bytes) |bytes| std.heap.page_allocator.free(bytes);
                }
                self.mutex.unlock();

                // Brief pause between cameras
                std.time.sleep(2 * std.time.ns_per_s);
            }

            // Wait before next full cycle
            var waited: u64 = 0;
            while (waited < POLL_INTERVAL_NS and !self.shutdown.load(.acquire)) {
                std.time.sleep(std.time.ns_per_s);
                waited += std.time.ns_per_s;
            }
        }
    }
};

// ---------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------

fn fetchSnapshot(client: *std.http.Client, url: []const u8) ?[]u8 {
    const uri = std.Uri.parse(url) catch return null;
    const body = httpGet(client, uri) orelse return null;
    if (body.items.len == 0) {
        body.deinit();
        return null;
    }
    // Transfer to owned slice
    const result = std.heap.page_allocator.alloc(u8, body.items.len) catch {
        body.deinit();
        return null;
    };
    @memcpy(result, body.items);
    body.deinit();
    return result;
}

fn httpGet(client: *std.http.Client, uri: std.Uri) ?std.ArrayList(u8) {
    return httpGetFollow(client, uri, 0);
}

fn httpGetFollow(client: *std.http.Client, uri: std.Uri, depth: u8) ?std.ArrayList(u8) {
    if (depth > 10) return null;
    var server_header_buf: [16384]u8 = undefined;
    var req = client.open(.GET, uri, .{
        .server_header_buffer = &server_header_buf,
        .redirect_behavior = .unhandled,
        .headers = .{},
    }) catch return null;
    defer req.deinit();

    req.send() catch return null;
    req.finish() catch return null;
    req.wait() catch return null;

    const status = @intFromEnum(req.response.status);
    if (status >= 301 and status <= 308) {
        const location = req.response.location orelse return null;
        const next_uri = std.Uri.parse(location) catch return null;
        return httpGetFollow(client, next_uri, depth + 1);
    }

    if (req.response.status != .ok) {
        std.debug.print("CAMS: HTTP {d}\n", .{status});
        return null;
    }

    var body = std.ArrayList(u8).init(std.heap.page_allocator);
    var reader = req.reader();
    reader.readAllArrayList(&body, 4 * 1024 * 1024) catch {
        body.deinit();
        return null;
    };
    return body;
}

fn detectFormat(bytes: []const u8) [*:0]const u8 {
    if (bytes.len >= 2 and bytes[0] == 0xFF and bytes[1] == 0xD8) return ".jpg";
    if (bytes.len >= 4 and bytes[0] == 0x89 and bytes[1] == 0x50 and bytes[2] == 0x4E and bytes[3] == 0x47) return ".png";
    if (bytes.len >= 4 and bytes[0] == 'R' and bytes[1] == 'I' and bytes[2] == 'F' and bytes[3] == 'F') return ".webp";
    return ".jpg";
}

fn jsonFloat(val: std.json.Value) ?f32 {
    return switch (val) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}
