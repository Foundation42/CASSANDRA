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

    // 3D mode
    begin3d, // enter 3D mode with camera
    end3d, // back to 2D
    line3d,
    cube3d,
    triangle3d,
    cube3d_solid,
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
    tex_front: rl.c.RenderTexture2D = undefined, // blitted to screen
    tex_back: rl.c.RenderTexture2D = undefined, // being rendered into
    width: u16 = 320,
    height: u16 = 240,
    tex_loaded: bool = false,
    needs_resize: bool = false,
    screen_x: f32 = 10,
    screen_y: f32 = 10,
    in_frame: bool = false, // between begin/end
    in_3d: bool = false, // between begin3d/end3d
    has_good_frame: bool = false, // the RenderTexture contains a fully rendered frame
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
                rl.c.UnloadRenderTexture(d.tex_front);
                rl.c.UnloadRenderTexture(d.tex_back);
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
                    // Legacy — camera now set via begin3d
                },
                .begin_frame => {
                    if (!d.active) continue;
                    self.ensureTexture(d);
                    rl.c.BeginTextureMode(d.tex_back);
                    rl.c.ClearBackground(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
                    d.in_frame = true;
                },
                .end_frame => {
                    if (d.in_3d) {
                        rl.c.EndMode3D();
                        d.in_3d = false;
                    }
                    if (d.in_frame) {
                        rl.c.EndTextureMode();
                        d.in_frame = false;
                        // Swap: back becomes front (complete frame ready to blit)
                        const tmp = d.tex_front;
                        d.tex_front = d.tex_back;
                        d.tex_back = tmp;
                        d.has_good_frame = true;
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
                .begin3d => {
                    if (!d.in_frame) continue;
                    // f[0..2] = camera position, f[3..5] = target, f[6] = fovy
                    const cam3d = rl.c.Camera3D{
                        .position = .{ .x = cmd.f[0], .y = cmd.f[1], .z = cmd.f[2] },
                        .target = .{ .x = cmd.f[3], .y = cmd.f[4], .z = cmd.f[5] },
                        .up = .{ .x = 0, .y = 1, .z = 0 },
                        .fovy = if (cmd.f[6] > 0) cmd.f[6] else 45.0,
                        .projection = rl.c.CAMERA_PERSPECTIVE,
                    };
                    rl.c.BeginMode3D(cam3d);
                    d.in_3d = true;
                },
                .end3d => {
                    if (d.in_3d) {
                        rl.c.EndMode3D();
                        d.in_3d = false;
                    }
                },
                .line3d => {
                    if (!d.in_frame) continue;
                    rl.c.DrawLine3D(
                        .{ .x = cmd.f[0], .y = cmd.f[1], .z = cmd.f[2] },
                        .{ .x = cmd.f[3], .y = cmd.f[4], .z = cmd.f[5] },
                        toRlColor(cmd.color),
                    );
                },
                .cube3d => {
                    if (!d.in_frame) continue;
                    // Wireframe cube: position + size
                    rl.c.DrawCubeWires(
                        .{ .x = cmd.f[0], .y = cmd.f[1], .z = cmd.f[2] },
                        cmd.f[3], cmd.f[3], cmd.f[3], // width, height, length = size
                        toRlColor(cmd.color),
                    );
                },
                .triangle3d => {
                    if (!d.in_frame) continue;
                    rl.c.DrawTriangle3D(
                        .{ .x = cmd.f[0], .y = cmd.f[1], .z = cmd.f[2] },
                        .{ .x = cmd.f[3], .y = cmd.f[4], .z = cmd.f[5] },
                        .{ .x = cmd.f[6], .y = cmd.f[7], .z = cmd.f[8] },
                        toRlColor(cmd.color),
                    );
                },
                .cube3d_solid => {
                    if (!d.in_frame) continue;
                    rl.c.DrawCube(
                        .{ .x = cmd.f[0], .y = cmd.f[1], .z = cmd.f[2] },
                        cmd.f[3], cmd.f[3], cmd.f[3],
                        toRlColor(cmd.color),
                    );
                },
            }
        }

        // Safety: force-close any open texture/3D modes that didn't get an end command this frame
        for (&self.displays) |*d| {
            if (d.in_3d) {
                rl.c.EndMode3D();
                d.in_3d = false;
            }
            if (d.in_frame) {
                rl.c.EndTextureMode();
                d.in_frame = false;
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
                rl.c.UnloadRenderTexture(d.tex_front);
                rl.c.UnloadRenderTexture(d.tex_back);
                d.tex_loaded = false;
                d.has_good_frame = false;
                continue;
            }
            if (!d.active or !d.tex_loaded or !d.has_good_frame) continue;
            // Make sure we're not still in a frame
            if (d.in_frame) {
                rl.c.EndTextureMode();
                d.in_frame = false;
            }
            const tex = d.tex_front.texture;
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
            if (d.tex_loaded) {
                rl.c.UnloadRenderTexture(d.tex_front);
                rl.c.UnloadRenderTexture(d.tex_back);
            }
            d.tex_front = rl.c.LoadRenderTexture(@intCast(d.width), @intCast(d.height));
            d.tex_back = rl.c.LoadRenderTexture(@intCast(d.width), @intCast(d.height));
            rl.c.SetTextureFilter(d.tex_front.texture, rl.c.TEXTURE_FILTER_BILINEAR);
            rl.c.SetTextureFilter(d.tex_back.texture, rl.c.TEXTURE_FILTER_BILINEAR);
            for ([_]rl.c.RenderTexture2D{ d.tex_front, d.tex_back }) |tex| {
                rl.c.BeginTextureMode(tex);
                rl.c.ClearBackground(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
                rl.c.EndTextureMode();
            }
            d.tex_loaded = true;
            d.needs_resize = false;
        }
    }
};
