const rl = @import("rl.zig");
const constants = @import("constants.zig");
const data = @import("data.zig");
const bvh = @import("bvh.zig");
const ui = @import("ui.zig");
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
    double_clicked: bool = false, // true for one frame on double-click
    last_click_time: f64 = 0,

    // Animated zoom transition
    anim_active: bool = false,
    anim_progress: f32 = 0, // 0..1
    anim_from_zoom: f32 = 0,
    anim_to_zoom: f32 = 0,
    anim_from_target: rl.Vector2 = .{ .x = 0, .y = 0 },
    anim_to_target: rl.Vector2 = .{ .x = 0, .y = 0 },

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

    const MAX_ZOOM: f32 = 500.0;
    const MIN_ZOOM: f32 = 2.0;
    const ANIM_DURATION: f32 = 1.0; // seconds

    pub fn startAnim(self: *CameraState, to_zoom: f32, to_target: rl.Vector2) void {
        self.anim_from_zoom = self.cam.zoom;
        self.anim_to_zoom = to_zoom;
        self.anim_from_target = self.cam.target;
        self.anim_to_target = to_target;
        self.anim_progress = 0;
        self.anim_active = true;
    }

    // Smooth ease-in-out
    fn easeInOut(t: f32) f32 {
        return t * t * (3.0 - 2.0 * t);
    }

    pub fn update(self: *CameraState, points: ?[]const data.Point, sw: c_int, sh: c_int, frame_bvh: ?*const bvh.FrameBvh, cf: *const ui.ClusterFilter) void {
        self.cam.offset = rl.vec2(@as(f32, @floatFromInt(sw)) / 2.0, @as(f32, @floatFromInt(sh)) / 2.0);

        // Drive animation
        if (self.anim_active) {
            self.anim_progress += rl.getFrameTime() / ANIM_DURATION;
            if (self.anim_progress >= 1.0) {
                self.anim_progress = 1.0;
                self.anim_active = false;
            }
            const t = easeInOut(self.anim_progress);
            // Zoom in log space so visual rate of change is uniform
            const log_from = @log(self.anim_from_zoom);
            const log_to = @log(self.anim_to_zoom);
            self.cam.zoom = @exp(log_from + (log_to - log_from) * t);
            self.cam.target.x = self.anim_from_target.x + (self.anim_to_target.x - self.anim_from_target.x) * t;
            self.cam.target.y = self.anim_from_target.y + (self.anim_to_target.y - self.anim_from_target.y) * t;
        }

        const wheel = rl.getMouseWheelMove();
        if (wheel != 0) {
            self.anim_active = false; // cancel animation on manual zoom
            const mouse_pos = rl.getMousePosition();
            const world_before = rl.getScreenToWorld2D(mouse_pos, self.cam);

            self.cam.zoom *= if (wheel > 0) 1.1 else 1.0 / 1.1;
            self.cam.zoom = std.math.clamp(self.cam.zoom, MIN_ZOOM, MAX_ZOOM);

            const world_after = rl.getScreenToWorld2D(mouse_pos, self.cam);
            self.cam.target.x += world_before.x - world_after.x;
            self.cam.target.y += world_before.y - world_after.y;
        }

        if (rl.isMouseButtonPressed(rl.MOUSE_BUTTON_RIGHT)) {
            self.anim_active = false;
            self.dragging = true;
            self.drag_start = rl.getMousePosition();
        }
        self.double_clicked = false;
        if (rl.isMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) {
            const mouse_pos = rl.getMousePosition();
            if (mouse_pos.y < @as(f32, @floatFromInt(sh)) - 50) {
                const world_pos = rl.getScreenToWorld2D(mouse_pos, self.cam);
                const hit = hitTest(world_pos, points, self.cam.zoom, frame_bvh, cf);
                self.selected_point = hit;

                // Double-click detection (anywhere within 400ms)
                const now = rl.c.GetTime();
                if (now - self.last_click_time < 0.4) {
                    self.double_clicked = true;
                    self.last_click_time = 0;

                    // Animate: zoom in to cursor position, or zoom out if already at max
                    // Skip if another system (e.g. worldmap) already started an animation this frame
                    if (self.anim_active and self.anim_progress < 0.05) {
                        // Animation already queued this frame, don't override
                    } else if (self.cam.zoom >= MAX_ZOOM * 0.9) {
                        const swf: f32 = @floatFromInt(sw);
                        const shf: f32 = @floatFromInt(sh);
                        const m: f32 = 0.9;
                        const fit_zoom = @min((swf * m) / self.bounds.width(), (shf * m) / self.bounds.height());
                        self.startAnim(fit_zoom, self.bounds.center());
                    } else {
                        self.startAnim(MAX_ZOOM, world_pos);
                    }
                } else {
                    self.last_click_time = now;
                }

                // Left-click on empty space starts a drag
                if (hit == null) {
                    self.dragging = true;
                    self.drag_start = mouse_pos;
                }
            }
        }
        if (rl.isMouseButtonReleased(rl.MOUSE_BUTTON_RIGHT) or rl.isMouseButtonReleased(rl.MOUSE_BUTTON_LEFT)) {
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

        if (rl.isKeyPressed(rl.KEY_HOME)) {
            self.anim_active = false;
            self.fitToScreen(sw, sh);
            self.selected_point = null;
        }

        if (rl.isKeyPressed(rl.KEY_ESCAPE)) {
            self.selected_point = null;
        }
    }
};

fn hitTest(world_pos: rl.Vector2, points: ?[]const data.Point, zoom: f32, frame_bvh: ?*const bvh.FrameBvh, cf: *const ui.ClusterFilter) ?u16 {
    const hit_radius = 15.0 / zoom;

    // Use BVH fast path if available, then validate cluster visibility
    if (frame_bvh) |fb| {
        const idx = fb.nearest(world_pos.x, world_pos.y, hit_radius) orelse return null;
        if (points) |pts| {
            if (idx < pts.len and !cf.isVisible(pts[idx].cluster)) return null;
        }
        return idx;
    }

    // Fallback: linear scan
    const pts = points orelse return null;
    var best_dist: f32 = hit_radius * hit_radius;
    var best_idx: ?u16 = null;

    for (pts, 0..) |p, i| {
        if (!cf.isVisible(p.cluster)) continue;
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
