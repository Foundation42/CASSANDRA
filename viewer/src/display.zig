const std = @import("std");
const rl = @import("rl.zig");

pub const MAX_DISPLAYS: usize = 4;

// ---------------------------------------------------------------
// Color helper
// ---------------------------------------------------------------

pub const Color4 = extern struct { r: u8, g: u8, b: u8, a: u8 };

pub fn toRlColor(c: Color4) rl.c.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

pub fn fromU32(v: u32) Color4 {
    return .{
        .r = @truncate(v),
        .g = @truncate(v >> 8),
        .b = @truncate(v >> 16),
        .a = @truncate(v >> 24),
    };
}

// ---------------------------------------------------------------
// Draw command — compact, flows through the ring
// ---------------------------------------------------------------

pub const CmdTag = enum(u8) {
    // Control
    begin_frame, // starts drawing to RenderTexture
    end_frame, // present: stops drawing
    create, // create/resize display (w,h in f[0],f[1])
    destroy,
    move_display, // screen position (x,y in f[0],f[1])
    set_camera, // dist, pitch, yaw in f[0..2]

    // 2D primitives
    clear,
    line,
    rect,
    rect_lines,
    circle,
    triangle,
    text,
    pixel,

    // 3D wireframe
    line3d,
    cube3d,
};

pub const DrawCmd = struct {
    tag: CmdTag,
    display_id: u8 = 0,
    color: Color4 = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    f: [12]f32 = .{0} ** 12,
    text_buf: [64]u8 = .{0} ** 64,
    text_len: u8 = 0,
};

// ---------------------------------------------------------------
// Command ring buffer — producer/consumer, grows if needed
// ---------------------------------------------------------------

const INITIAL_RING_SIZE: usize = 256;

pub const CmdRing = struct {
    buf: []DrawCmd,
    capacity: usize = 0,
    head: usize = 0, // write position (producer)
    tail: usize = 0, // read position (consumer)
    mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CmdRing {
        const buf = allocator.alloc(DrawCmd, INITIAL_RING_SIZE) catch {
            return .{
                .buf = &.{},
                .capacity = 0,
                .allocator = allocator,
            };
        };
        return .{
            .buf = buf,
            .capacity = INITIAL_RING_SIZE,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CmdRing) void {
        if (self.capacity > 0) {
            self.allocator.free(self.buf);
            self.capacity = 0;
        }
    }

    /// Push a command (producer/worker thread)
    pub fn push(self: *CmdRing, cmd: DrawCmd) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const next = (self.head + 1) % self.capacity;
        if (next == self.tail) {
            // Ring full — grow
            self.grow();
        }
        self.buf[self.head] = cmd;
        self.head = (self.head + 1) % self.capacity;
    }

    /// Pop a command (consumer/main thread). Returns null if empty.
    pub fn pop(self: *CmdRing) ?DrawCmd {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.tail == self.head) return null;
        const cmd = self.buf[self.tail];
        self.tail = (self.tail + 1) % self.capacity;
        return cmd;
    }

    fn grow(self: *CmdRing) void {
        const new_cap = if (self.capacity == 0) INITIAL_RING_SIZE else self.capacity * 2;
        const new_buf = self.allocator.alloc(DrawCmd, new_cap) catch return;

        // Linearize existing data
        if (self.capacity > 0) {
            var i: usize = 0;
            var pos = self.tail;
            while (pos != self.head) {
                new_buf[i] = self.buf[pos];
                pos = (pos + 1) % self.capacity;
                i += 1;
            }
            self.allocator.free(self.buf);
            self.tail = 0;
            self.head = i;
        }
        self.buf = new_buf;
        self.capacity = new_cap;
    }
};

// ---------------------------------------------------------------
// Display — just the render target and camera, no command storage
// ---------------------------------------------------------------

pub const Display = struct {
    active: bool = false,
    tex: rl.c.RenderTexture2D = undefined,
    width: u16 = 320,
    height: u16 = 240,
    tex_loaded: bool = false,
    needs_resize: bool = false,
    screen_x: f32 = 10,
    screen_y: f32 = 10,
    in_frame: bool = false, // between begin/end

    // 3D camera
    cam_dist: f32 = 5.0,
    cam_pitch: f32 = 0.3,
    cam_yaw: f32 = 0.0,
};

// ---------------------------------------------------------------
// Display Manager — thin, processes commands from ring each frame
// ---------------------------------------------------------------

pub const DisplayManager = struct {
    displays: [MAX_DISPLAYS]Display = .{.{}} ** MAX_DISPLAYS,
    ring: CmdRing,

    pub fn init(allocator: std.mem.Allocator) DisplayManager {
        return .{ .ring = CmdRing.init(allocator) };
    }

    pub fn deinit(self: *DisplayManager) void {
        for (&self.displays) |*d| {
            if (d.tex_loaded) {
                rl.c.UnloadRenderTexture(d.tex);
                d.tex_loaded = false;
            }
        }
        self.ring.deinit();
    }

    /// Process all pending commands from the ring. Call from main thread each frame.
    pub fn processAndRender(self: *DisplayManager) void {
        while (self.ring.pop()) |cmd| {
            const id = cmd.display_id;
            if (id >= MAX_DISPLAYS) continue;
            var d = &self.displays[id];

            switch (cmd.tag) {
                .create => {
                    d.active = true;
                    d.width = @intFromFloat(cmd.f[0]);
                    d.height = @intFromFloat(cmd.f[1]);
                    d.needs_resize = true;
                },
                .destroy => {
                    if (d.in_frame) {
                        rl.c.EndTextureMode();
                        d.in_frame = false;
                    }
                    d.active = false;
                },
                .move_display => {
                    d.screen_x = cmd.f[0];
                    d.screen_y = cmd.f[1];
                },
                .set_camera => {
                    d.cam_dist = cmd.f[0];
                    d.cam_pitch = cmd.f[1];
                    d.cam_yaw = cmd.f[2];
                },
                .begin_frame => {
                    if (!d.active) continue;
                    self.ensureTexture(d);
                    rl.c.BeginTextureMode(d.tex);
                    rl.c.ClearBackground(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
                    d.in_frame = true;
                },
                .end_frame => {
                    if (d.in_frame) {
                        rl.c.EndTextureMode();
                        d.in_frame = false;
                    }
                },
                // 2D primitives
                .clear => {
                    if (!d.in_frame) continue;
                    rl.c.ClearBackground(toRlColor(cmd.color));
                },
                .line => {
                    if (!d.in_frame) continue;
                    rl.c.DrawLineEx(
                        .{ .x = cmd.f[0], .y = cmd.f[1] },
                        .{ .x = cmd.f[2], .y = cmd.f[3] },
                        if (cmd.f[4] > 0) cmd.f[4] else 1.0,
                        toRlColor(cmd.color),
                    );
                },
                .rect => {
                    if (!d.in_frame) continue;
                    rl.c.DrawRectangleV(
                        .{ .x = cmd.f[0], .y = cmd.f[1] },
                        .{ .x = cmd.f[2], .y = cmd.f[3] },
                        toRlColor(cmd.color),
                    );
                },
                .rect_lines => {
                    if (!d.in_frame) continue;
                    rl.c.DrawRectangleLinesEx(
                        .{ .x = cmd.f[0], .y = cmd.f[1], .width = cmd.f[2], .height = cmd.f[3] },
                        if (cmd.f[4] > 0) cmd.f[4] else 1.0,
                        toRlColor(cmd.color),
                    );
                },
                .circle => {
                    if (!d.in_frame) continue;
                    rl.c.DrawCircleV(.{ .x = cmd.f[0], .y = cmd.f[1] }, cmd.f[2], toRlColor(cmd.color));
                },
                .triangle => {
                    if (!d.in_frame) continue;
                    rl.c.DrawTriangle(
                        .{ .x = cmd.f[0], .y = cmd.f[1] },
                        .{ .x = cmd.f[2], .y = cmd.f[3] },
                        .{ .x = cmd.f[4], .y = cmd.f[5] },
                        toRlColor(cmd.color),
                    );
                },
                .text => {
                    if (!d.in_frame) continue;
                    var buf: [65]u8 = undefined;
                    @memcpy(buf[0..cmd.text_len], cmd.text_buf[0..cmd.text_len]);
                    buf[cmd.text_len] = 0;
                    const size: c_int = if (cmd.f[2] > 0) @intFromFloat(cmd.f[2]) else 10;
                    rl.c.DrawText(&buf, @intFromFloat(cmd.f[0]), @intFromFloat(cmd.f[1]), size, toRlColor(cmd.color));
                },
                .pixel => {
                    if (!d.in_frame) continue;
                    rl.c.DrawPixelV(.{ .x = cmd.f[0], .y = cmd.f[1] }, toRlColor(cmd.color));
                },
                .line3d => {
                    if (!d.in_frame) continue;
                    const p1 = project3D(d, cmd.f[0], cmd.f[1], cmd.f[2]);
                    const p2 = project3D(d, cmd.f[3], cmd.f[4], cmd.f[5]);
                    rl.c.DrawLineEx(.{ .x = p1[0], .y = p1[1] }, .{ .x = p2[0], .y = p2[1] }, 1.5, toRlColor(cmd.color));
                },
                .cube3d => {
                    if (!d.in_frame) continue;
                    drawWireCube(d, cmd.f[0], cmd.f[1], cmd.f[2], cmd.f[3], cmd.f[4], cmd.f[5], toRlColor(cmd.color));
                },
            }
        }
    }

    /// Blit all active displays to screen, clean up inactive ones
    pub fn drawAll(self: *DisplayManager) void {
        for (&self.displays) |*d| {
            // Clean up textures for deactivated displays (must happen on main/GPU thread)
            if (!d.active and d.tex_loaded) {
                if (d.in_frame) {
                    rl.c.EndTextureMode();
                    d.in_frame = false;
                }
                rl.c.UnloadRenderTexture(d.tex);
                d.tex_loaded = false;
                continue;
            }
            if (!d.active or !d.tex_loaded) continue;
            // Make sure we're not still in a frame
            if (d.in_frame) {
                rl.c.EndTextureMode();
                d.in_frame = false;
            }
            const tex = d.tex.texture;
            const w: f32 = @floatFromInt(tex.width);
            const h: f32 = @floatFromInt(tex.height);
            const src = rl.c.Rectangle{ .x = 0, .y = 0, .width = w, .height = -h };
            const dst = rl.c.Rectangle{ .x = d.screen_x, .y = d.screen_y, .width = w, .height = h };
            rl.c.BeginBlendMode(rl.c.BLEND_ALPHA);
            rl.c.DrawTexturePro(tex, src, dst, .{ .x = 0, .y = 0 }, 0, rl.c.WHITE);
            rl.c.EndBlendMode();
        }
    }

    fn ensureTexture(self: *DisplayManager, d: *Display) void {
        _ = self;
        if (!d.tex_loaded or d.needs_resize) {
            if (d.tex_loaded) rl.c.UnloadRenderTexture(d.tex);
            d.tex = rl.c.LoadRenderTexture(@intCast(d.width), @intCast(d.height));
            rl.c.SetTextureFilter(d.tex.texture, rl.c.TEXTURE_FILTER_BILINEAR);
            // Clear to transparent on creation so no VRAM garbage shows
            rl.c.BeginTextureMode(d.tex);
            rl.c.ClearBackground(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
            rl.c.EndTextureMode();
            d.tex_loaded = true;
            d.needs_resize = false;
        }
    }
};

// ---------------------------------------------------------------
// 3D Projection
// ---------------------------------------------------------------

fn project3D(d: *const Display, x: f32, y: f32, z: f32) [2]f32 {
    const cy = @cos(d.cam_yaw);
    const sy = @sin(d.cam_yaw);
    const cp = @cos(d.cam_pitch);
    const sp = @sin(d.cam_pitch);

    const rx = x * cy - z * sy;
    const rz = x * sy + z * cy;
    const ry = y * cp - rz * sp;
    const rz2 = y * sp + rz * cp;

    const depth = rz2 + d.cam_dist;
    const scale = d.cam_dist / @max(depth, 0.01);
    const hw: f32 = @as(f32, @floatFromInt(d.width)) / 2.0;
    const hh: f32 = @as(f32, @floatFromInt(d.height)) / 2.0;

    return .{ hw + rx * scale * hw * 0.5, hh - ry * scale * hh * 0.5 };
}

fn drawWireCube(d: *const Display, cx: f32, cy: f32, cz: f32, size: f32, rx: f32, ry: f32, color: rl.c.Color) void {
    const s = size * 0.5;
    const verts = [8][3]f32{
        .{ -s, -s, -s }, .{ s, -s, -s }, .{ s, s, -s }, .{ -s, s, -s },
        .{ -s, -s, s },  .{ s, -s, s },  .{ s, s, s },  .{ -s, s, s },
    };

    var projected: [8][2]f32 = undefined;
    const crx = @cos(rx);
    const srx = @sin(rx);
    const cry = @cos(ry);
    const sry = @sin(ry);

    for (0..8) |i| {
        const vx = verts[i][0];
        const vy = verts[i][1];
        const vz = verts[i][2];
        const x2 = vx * cry - vz * sry;
        const z2 = vx * sry + vz * cry;
        const y2 = vy * crx - z2 * srx;
        const z3 = vy * srx + z2 * crx;
        projected[i] = project3D(d, cx + x2, cy + y2, cz + z3);
    }

    const edges = [12][2]u8{
        .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 },
        .{ 4, 5 }, .{ 5, 6 }, .{ 6, 7 }, .{ 7, 4 },
        .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 },
    };

    for (edges) |e| {
        const a = projected[e[0]];
        const b = projected[e[1]];
        rl.c.DrawLineEx(.{ .x = a[0], .y = a[1] }, .{ .x = b[0], .y = b[1] }, 1.5, color);
    }
}
