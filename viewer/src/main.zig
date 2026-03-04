const std = @import("std");
const rl = @import("rl.zig");
const data = @import("data.zig");
const render = @import("render.zig");
const camera = @import("camera.zig");
const timeline_mod = @import("timeline.zig");
const ui = @import("ui.zig");
const constants = @import("constants.zig");
const physics = @import("physics.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    std.debug.print("CASSANDRA Nucleus Viewer\n", .{});
    std.debug.print("Loading data...\n", .{});

    var nd = data.NucleusData.init(allocator);

    // Load positions
    try data.loadPositions(&nd, "../nucleus_positions.json");
    std.debug.print("Loaded {d} positions\n", .{nd.positions.count()});

    // Scan for snapshots
    const timestamps = try data.scanSnapshots(allocator, "../snapshots");
    std.debug.print("Found {d} snapshot timestamps\n", .{timestamps.len});

    if (timestamps.len == 0) {
        std.debug.print("ERROR: No snapshots found in ../snapshots/\n", .{});
        return;
    }

    // Load the latest snapshot to determine attractors
    var latest_snapshot = try data.loadSnapshot(&nd, timestamps[timestamps.len - 1].snap_path);
    const attractor_synsets = try data.findAttractors(&latest_snapshot, allocator);
    std.debug.print("Attractors: ", .{});
    for (attractor_synsets) |a| {
        std.debug.print("{s} ", .{a});
    }
    std.debug.print("\n", .{});

    // K-means on attractors
    const k: u8 = @intCast(@min(constants.NUM_CLUSTERS, attractor_synsets.len));
    const attractor_labels = try data.kmeansAttractors(attractor_synsets, &nd.anchors, k, allocator);

    // Store attractor name indices
    for (attractor_synsets, 0..) |aname, i| {
        nd.attractor_names[i] = nd.name_to_idx.get(aname) orelse 0;
    }
    nd.num_attractors = attractor_synsets.len;

    // Reconstruct recency for each timestamp
    std.debug.print("Reconstructing recency...\n", .{});
    const recencies = try data.reconstructRecency(timestamps, &nd);

    // Build keyframes
    // Stretch x positions to fill widescreen
    const x_scale: f32 = @as(f32, @floatFromInt(constants.WINDOW_W)) / @as(f32, @floatFromInt(constants.WINDOW_H));

    std.debug.print("Building keyframes (x_scale={d:.2})...\n", .{x_scale});
    var prev_snap: ?std.StringHashMap(data.SnapshotEntry) = null;
    for (timestamps, 0..) |ts_info, ti| {
        var snapshot = try data.loadSnapshot(&nd, ts_info.snap_path);
        var delta_map = data.loadDelta(&nd, ts_info.delta_path) catch std.StringHashMap(i64).init(allocator);

        const kf = try data.buildKeyframe(
            &nd,
            &snapshot,
            &delta_map,
            &recencies[ti],
            if (prev_snap) |*ps| ps else null,
            attractor_synsets,
            attractor_labels,
            ts_info.timestamp,
            x_scale,
        );
        try nd.keyframes.append(kf);

        std.debug.print("  Keyframe {s}: {d} points, max_delta={d:.0}\n", .{
            ts_info.timestamp, kf.points.len, kf.max_delta,
        });

        if (prev_snap) |*ps| ps.deinit();
        prev_snap = snapshot;
    }
    latest_snapshot.deinit();

    std.debug.print("Ready! {d} keyframes, {d} names\n", .{
        nd.keyframes.items.len,
        nd.synset_names.items.len,
    });

    // --- Raylib init ---
    rl.setConfigFlags(rl.FLAG_MSAA_4X_HINT | rl.FLAG_WINDOW_RESIZABLE | rl.FLAG_VSYNC_HINT);
    rl.initWindow(constants.WINDOW_W, constants.WINDOW_H, "CASSANDRA — Nucleus Viewer");
    defer rl.closeWindow();
    rl.setTargetFPS(constants.TARGET_FPS);

    const font = rl.getFontDefault();

    // Compute bounds from the last keyframe (has all points)
    const bounds = camera.computeBounds(nd.keyframes.items[nd.keyframes.items.len - 1].points);
    var cam_state = camera.CameraState.init(bounds, rl.getScreenWidth(), rl.getScreenHeight());
    var tl = timeline_mod.Timeline.init(@intCast(nd.keyframes.items.len));
    try tl.computeTickFracs(nd.keyframes.items, allocator);
    var search = ui.SearchState{};
    var cluster_filter = ui.ClusterFilter{};

    var interp_buf: ?[]data.Point = null;
    var phys = physics.PhysicsState.init(allocator);
    var phys_buf: ?[]data.Point = null;
    var prev_ki: u32 = std.math.maxInt(u32);

    while (!rl.windowShouldClose()) {
        const dt = rl.getFrameTime();

        // Input
        if (rl.isKeyPressed(rl.KEY_F11) or rl.isKeyPressed(rl.KEY_F)) {
            rl.toggleFullscreen();
        }
        if (search.active) {
            search.handleInput();
        } else {
            search.handleInput();
            tl.handleInput();
            cluster_filter.handleInput();
            if (rl.isKeyPressed(rl.KEY_G)) {
                phys.toggle();
            }
        }
        tl.update(dt);

        // Current points
        const keyframes = nd.keyframes.items;
        const ki = @min(tl.keyframeIndex(), @as(u32, @intCast(keyframes.len - 1)));
        const frac = tl.interpFraction();

        const current_points: []const data.Point = blk: {
            if (frac < 0.01 or ki >= keyframes.len - 1) {
                break :blk keyframes[ki].points;
            } else {
                if (interp_buf) |buf| allocator.free(buf);
                interp_buf = try timeline_mod.lerpPoints(
                    keyframes[ki].points,
                    keyframes[ki + 1].points,
                    frac,
                    allocator,
                );
                break :blk interp_buf.?;
            }
        };

        const cur_kf = keyframes[ki];

        // --- Physics integration ---
        if (phys.isActive()) {
            // Re-sync when keyframe changes or on every frame to track interpolated activity
            if (ki != prev_ki) {
                try phys.syncToPoints(current_points, cur_kf.max_delta);
                prev_ki = ki;
            } else {
                // Update activity values from interpolated points each frame
                const md = @max(cur_kf.max_delta, 1.0);
                for (current_points, 0..) |p, idx| {
                    if (idx < phys.count and phys.name_indices[idx] == p.name_idx) {
                        phys.activity[idx] = p.delta / md;
                    }
                }
            }
            phys.step(dt);
            phys.updateBlend(dt);

            // Copy points into mutable buffer and apply physics positions
            if (phys_buf) |buf| allocator.free(buf);
            phys_buf = try allocator.alloc(data.Point, current_points.len);
            @memcpy(phys_buf.?, current_points);
            phys.applyToPoints(phys_buf.?);
        } else {
            phys.updateBlend(dt); // finish blending_out transition
        }

        const render_points: []const data.Point = if (phys.isActive())
            phys_buf.?
        else
            current_points;

        const sw = rl.getScreenWidth();
        const sh = rl.getScreenHeight();
        cam_state.update(render_points, sw, sh);

        // --- Drawing ---
        rl.beginDrawing();
        rl.clearBackground(constants.BG_COLOR);

        // World-space (through Camera2D)
        rl.beginMode2D(cam_state.cam);
        render.drawGrid(cam_state.cam, sw, sh);
        render.drawConnectionLines(render_points, &nd, &cluster_filter);
        render.drawGlow(render_points, cur_kf.max_delta, &cluster_filter);
        render.drawDots(render_points, cur_kf.max_total, cur_kf.max_delta, &cluster_filter);
        render.drawAttractorRings(render_points, &cluster_filter);
        render.drawUncertaintyArrows(render_points, &cluster_filter);
        if (cam_state.selected_point) |sel| {
            render.drawHighlight(render_points, sel);
        }
        if (search.len > 0) {
            render.drawSearchHighlights(render_points, &nd, search.query());
        }
        rl.endMode2D();

        // Screen-space
        render.drawLabels(render_points, &nd, cam_state.cam, font, &cluster_filter);
        render.drawVignette(sw, sh);

        ui.drawHUD(font, cur_kf.timestamp, cur_kf.num_visible, cur_kf.num_hot, @intCast(keyframes.len), &tl, phys.isActive());
        ui.drawScrubber(&tl, font, sw, sh);
        ui.drawClusterFilter(&cluster_filter, sw);
        ui.drawSearchBar(&search, font, sw);

        if (cam_state.selected_point) |sel| {
            ui.drawDetailPanel(render_points, sel, &nd, font, sw);
        }

        rl.drawFPS(sw - 90, sh - 60);
        rl.endDrawing();
    }
}
