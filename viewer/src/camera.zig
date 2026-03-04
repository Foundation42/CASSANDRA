const rl = @import("rl.zig");
const constants = @import("constants.zig");
const data = @import("data.zig");
const std = @import("std");

pub const Bounds = struct {
    min_x: f32,
    max_x: f32,
    min_y: f32,
    max_y: f32,

    pub fn center(self: Bounds) rl.Vector2 {
        return rl.vec2((self.min_x + self.max_x) / 2.0, (self.min_y + self.max_y) / 2.0);
    }
    pub fn width(self: Bounds) f32 {
        return self.max_x - self.min_x;
    }
    pub fn height(self: Bounds) f32 {
        return self.max_y - self.min_y;
    }
};

pub fn computeBounds(points: []const data.Point) Bounds {
    var b = Bounds{
        .min_x = std.math.floatMax(f32),
        .max_x = -std.math.floatMax(f32),
        .min_y = std.math.floatMax(f32),
        .max_y = -std.math.floatMax(f32),
    };
    for (points) |p| {
        b.min_x = @min(b.min_x, p.x);
        b.max_x = @max(b.max_x, p.x);
        b.min_y = @min(b.min_y, p.y);
        b.max_y = @max(b.max_y, p.y);
    }
    return b;
}

pub const CameraState = struct {
    cam: rl.Camera2D,
    bounds: Bounds,
    dragging: bool = false,
    drag_start: rl.Vector2 = .{ .x = 0, .y = 0 },
    selected_point: ?u16 = null,

    pub fn init(b: Bounds, sw: c_int, sh: c_int) CameraState {
        var self = CameraState{
            .cam = undefined,
            .bounds = b,
        };
        self.fitToScreen(sw, sh);
        return self;
    }

    pub fn fitToScreen(self: *CameraState, sw: c_int, sh: c_int) void {
        const swf: f32 = @floatFromInt(sw);
        const shf: f32 = @floatFromInt(sh);
        const margin: f32 = 0.9;
        const zoom_x = (swf * margin) / self.bounds.width();
        const zoom_y = (shf * margin) / self.bounds.height();
        self.cam = .{
            .offset = rl.vec2(swf / 2.0, shf / 2.0),
            .target = self.bounds.center(),
            .rotation = 0,
            .zoom = @min(zoom_x, zoom_y),
        };
    }

    pub fn update(self: *CameraState, points: ?[]const data.Point, sw: c_int, sh: c_int) void {
        self.cam.offset = rl.vec2(@as(f32, @floatFromInt(sw)) / 2.0, @as(f32, @floatFromInt(sh)) / 2.0);

        const wheel = rl.getMouseWheelMove();
        if (wheel != 0) {
            const mouse_pos = rl.getMousePosition();
            const world_before = rl.getScreenToWorld2D(mouse_pos, self.cam);

            self.cam.zoom *= if (wheel > 0) 1.1 else 1.0 / 1.1;
            self.cam.zoom = std.math.clamp(self.cam.zoom, 2.0, 500.0);

            const world_after = rl.getScreenToWorld2D(mouse_pos, self.cam);
            self.cam.target.x += world_before.x - world_after.x;
            self.cam.target.y += world_before.y - world_after.y;
        }

        if (rl.isMouseButtonPressed(rl.MOUSE_BUTTON_RIGHT)) {
            self.dragging = true;
            self.drag_start = rl.getMousePosition();
        }
        if (rl.isMouseButtonReleased(rl.MOUSE_BUTTON_RIGHT)) {
            self.dragging = false;
        }
        if (self.dragging) {
            const mouse_pos = rl.getMousePosition();
            const dx = (mouse_pos.x - self.drag_start.x) / self.cam.zoom;
            const dy = (mouse_pos.y - self.drag_start.y) / self.cam.zoom;
            self.cam.target.x -= dx;
            self.cam.target.y -= dy;
            self.drag_start = mouse_pos;
        }

        if (rl.isMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) {
            const mouse_pos = rl.getMousePosition();
            if (mouse_pos.y < @as(f32, @floatFromInt(sh)) - 50) {
                const world_pos = rl.getScreenToWorld2D(mouse_pos, self.cam);
                self.selected_point = hitTest(world_pos, points, self.cam.zoom);
            }
        }

        if (rl.isKeyPressed(rl.KEY_HOME)) {
            self.fitToScreen(sw, sh);
            self.selected_point = null;
        }

        if (rl.isKeyPressed(rl.KEY_ESCAPE)) {
            self.selected_point = null;
        }
    }
};

fn hitTest(world_pos: rl.Vector2, points: ?[]const data.Point, zoom: f32) ?u16 {
    const pts = points orelse return null;
    const hit_radius = 15.0 / zoom;
    var best_dist: f32 = hit_radius * hit_radius;
    var best_idx: ?u16 = null;

    for (pts, 0..) |p, i| {
        const dx = world_pos.x - p.x;
        const dy = world_pos.y - p.y;
        const d2 = dx * dx + dy * dy;
        if (d2 < best_dist) {
            best_dist = d2;
            best_idx = @intCast(i);
        }
    }
    return best_idx;
}
