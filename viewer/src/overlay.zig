const std = @import("std");
const data = @import("data.zig");
const rl = @import("rl.zig");
const ui = @import("ui.zig");
const worldmap_mod = @import("worldmap.zig");

pub const OverlayItemHit = struct { item_idx: u16, dist_sq: f32 };
pub const OverlayHit = struct { overlay_idx: u8, item_idx: u16, dist_sq: f32 };
pub const Selection = union(enum) { none, concept: u16, overlay: OverlayHit };

/// Context passed to every overlay callback each frame.
pub const FrameContext = struct {
    render_points: []const data.Point,
    nd: *const data.NucleusData,
    cur_kf: data.Keyframe,
    cam: rl.Camera2D,
    sw: c_int,
    sh: c_int,
    visible: []const u16,
    wmap: ?*worldmap_mod.WorldMap,
    cluster_filter: *const ui.ClusterFilter,
    dt: f32,
    font: rl.Font,
    allocator: std.mem.Allocator,
};

/// Comptime generic dispatcher over a tuple of overlay structs.
///
/// Each overlay struct may implement any subset of:
///   - `enabled(*const Self) bool`         — required, controls all other callbacks
///   - `handleInput(*Self, *const FrameContext) void`
///   - `update(*Self, *const FrameContext) void`
///   - `drawWorld(*Self, *const FrameContext) void`   — inside Mode2D
///   - `drawScreen(*Self, *const FrameContext) void`  — screen-space
///   - `statusText(*const Self, []u8) usize`          — append to FX status line
pub fn OverlaySet(comptime T: type) type {
    return struct {
        overlays: T,

        const Self = @This();

        pub fn init() Self {
            return .{ .overlays = .{} };
        }

        /// Process toggle keys — call early in frame, no FrameContext needed.
        pub fn handleToggles(self: *Self) void {
            inline for (std.meta.fields(T)) |field| {
                const o = &@field(self.overlays, field.name);
                if (@hasDecl(field.type, "handleToggle")) {
                    o.handleToggle();
                }
            }
        }

        pub fn handleInput(self: *Self, fctx: *const FrameContext) void {
            inline for (std.meta.fields(T)) |field| {
                const o = &@field(self.overlays, field.name);
                if (o.enabled()) {
                    if (@hasDecl(field.type, "handleInput")) {
                        o.handleInput(fctx);
                    }
                }
            }
        }

        pub fn update(self: *Self, fctx: *const FrameContext) void {
            inline for (std.meta.fields(T)) |field| {
                const overlay = &@field(self.overlays, field.name);
                if (overlay.enabled()) {
                    if (@hasDecl(field.type, "update")) {
                        overlay.update(fctx);
                    }
                }
            }
        }

        pub fn drawWorld(self: *Self, fctx: *const FrameContext) void {
            inline for (std.meta.fields(T)) |field| {
                const overlay = &@field(self.overlays, field.name);
                if (overlay.enabled()) {
                    if (@hasDecl(field.type, "drawWorld")) {
                        overlay.drawWorld(fctx);
                    }
                }
            }
        }

        pub fn drawScreen(self: *Self, fctx: *const FrameContext) void {
            inline for (std.meta.fields(T)) |field| {
                const overlay = &@field(self.overlays, field.name);
                if (overlay.enabled()) {
                    if (@hasDecl(field.type, "drawScreen")) {
                        overlay.drawScreen(fctx);
                    }
                }
            }
        }

        /// Test all enabled overlays for a hit, return the closest.
        pub fn hitTest(self: *Self, world_pos: rl.Vector2, cam_zoom: f32) ?OverlayHit {
            var best: ?OverlayHit = null;
            const max_dist_sq = blk: {
                const r = 15.0 / cam_zoom;
                break :blk r * r;
            };
            inline for (std.meta.fields(T), 0..) |field, oi| {
                const o = &@field(self.overlays, field.name);
                if (o.enabled()) {
                    if (@hasDecl(field.type, "hitTest")) {
                        if (o.hitTest(world_pos, max_dist_sq)) |item_hit| {
                            const candidate = OverlayHit{
                                .overlay_idx = @intCast(oi),
                                .item_idx = item_hit.item_idx,
                                .dist_sq = item_hit.dist_sq,
                            };
                            if (best) |b| {
                                if (candidate.dist_sq < b.dist_sq) best = candidate;
                            } else {
                                best = candidate;
                            }
                        }
                    }
                }
            }
            return best;
        }

        /// Dispatch drawDetail to the overlay that owns the hit.
        pub fn drawDetail(self: *Self, fctx: *const FrameContext, hit: OverlayHit) void {
            inline for (std.meta.fields(T), 0..) |field, oi| {
                if (oi == hit.overlay_idx) {
                    const o = &@field(self.overlays, field.name);
                    if (@hasDecl(field.type, "drawDetail")) {
                        o.drawDetail(fctx, hit.item_idx);
                    }
                }
            }
        }

        /// Check if a particular overlay index is currently enabled.
        pub fn isEnabled(self: *const Self, overlay_idx: u8) bool {
            inline for (std.meta.fields(T), 0..) |field, oi| {
                if (oi == overlay_idx) {
                    return @field(self.overlays, field.name).enabled();
                }
            }
            return false;
        }

        pub fn statusText(self: *const Self, buf: []u8) usize {
            var total: usize = 0;
            inline for (std.meta.fields(T)) |field| {
                const overlay = &@field(self.overlays, field.name);
                if (overlay.enabled()) {
                    if (@hasDecl(field.type, "statusText")) {
                        total += overlay.statusText(buf[total..]);
                    }
                }
            }
            return total;
        }
    };
}
