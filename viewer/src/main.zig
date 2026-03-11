const std = @import("std");
const rl = @import("rl.zig");
const data = @import("data.zig");
const render = @import("render.zig");
const camera = @import("camera.zig");
const timeline_mod = @import("timeline.zig");
const ui = @import("ui.zig");
const constants = @import("constants.zig");
const physics = @import("physics.zig");
const live = @import("live.zig");
const bvh = @import("bvh.zig");
const effects = @import("effects.zig");
const navmesh = @import("navmesh.zig");
const worldmap_mod = @import("worldmap.zig");
const overlay_mod = @import("overlay.zig");
const perf_mod = @import("perf.zig");
const adsb = @import("overlays/adsb.zig");
const ais = @import("overlays/ais.zig");
const photo_mod = @import("photo.zig");
const overlay_db_mod = @import("overlay_db.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Parse CLI args
    var boot_window_secs: i64 = 86400; // default: 24h
    {
        var args = std.process.args();
        _ = args.next(); // skip argv[0]
        while (args.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "--window=")) {
                const val = arg["--window=".len..];
                boot_window_secs = std.fmt.parseInt(i64, val, 10) catch 86400;
            } else if (std.mem.eql(u8, arg, "--all")) {
                boot_window_secs = 0; // load everything
            }
        }
    }

    std.debug.print("CASSANDRA Nucleus Viewer\n", .{});
    if (boot_window_secs > 0) {
        std.debug.print("Boot window: {d}s ({d}h)\n", .{ boot_window_secs, @divTrunc(boot_window_secs, 3600) });
    } else {
        std.debug.print("Boot window: all snapshots\n", .{});
    }

    var nd = data.NucleusData.init(allocator);

    // Positions are loaded by the worker thread from SQLite
    std.debug.print("Positions will be loaded from SQLite by worker thread\n", .{});

    // --- Spawn worker thread (handles all snapshot loading + live) ---
    var running_recency = std.StringHashMap(i64).init(allocator);
    var nds = live.NdSnapshot.init(&nd, &running_recency);
    nds.boot_window_secs = boot_window_secs;
    var queue = live.LiveQueue{};
    queue.spawn(&nds);
    defer queue.requestShutdown();

    // --- Raylib init ---
    rl.setConfigFlags(rl.FLAG_MSAA_4X_HINT | rl.FLAG_WINDOW_RESIZABLE | rl.FLAG_VSYNC_HINT);
    rl.initWindow(constants.WINDOW_W, constants.WINDOW_H, "CASSANDRA — Nucleus Viewer");
    defer rl.closeWindow();
    rl.setTargetFPS(constants.TARGET_FPS);
    rl.c.SetExitKey(0); // Disable ESC-to-quit; ESC is used for clearing selection/search

    const font = rl.getFontDefault();

    // Load world map background
    var wmap: ?worldmap_mod.WorldMap = worldmap_mod.WorldMap.load(allocator, "data/world.bin") catch |err| blk: {
        std.debug.print("worldmap: load failed: {}, continuing without map\n", .{err});
        break :blk null;
    };
    _ = &wmap;

    // Start with default bounds — camera will fit when first data arrives
    const default_bounds = camera.Bounds{ .min_x = -20, .max_x = 20, .min_y = -20, .max_y = 20 };
    var cam_state = camera.CameraState.init(default_bounds, rl.getScreenWidth(), rl.getScreenHeight());
    var tl = timeline_mod.Timeline.init();
    tl.live = false; // Don't track latest during bootstrap; start from beginning
    var search = ui.SearchState{};
    var cluster_filter = ui.ClusterFilter{};

    var navmesh_on = false;
    var edges_on = true;
    var nav_paths: [navmesh.MAX_ATTRACTOR_PAIRS]navmesh.NavPath = undefined;
    var nav_num_paths: usize = 0;
    var nav_version: usize = 0;
    var navmesh_focus: ?u16 = null; // name_idx of focused attractor (null = show all)
    var nav_attractor_hash: u64 = 0; // hash of attractor set whose paths we currently have
    var nav_requested_hash: u64 = 0; // hash of attractor set we last requested from worker

    var interp_buf: ?[]data.Point = null;
    var phys = physics.PhysicsState.init(allocator);
    phys.toggle();
    var phys_buf: ?[]data.Point = null;
    var prev_ki: usize = std.math.maxInt(usize);
    var needs_camera_fit = true;

    // BVH and visible-set buffers (stack-allocated, ~90KB)
    var frame_bvh: bvh.FrameBvh = undefined;
    var visible_buf: [bvh.MAX_POINTS]u16 = undefined;

    // Post-processing effects (trails + bloom)
    var fx: effects.Effects = .{};
    defer fx.deinit();

    // Overlay persistence DB
    var overlay_db = overlay_db_mod.OverlayDb.open("overlay.db");
    defer if (overlay_db) |*db| db.close();

    // Overlay plugins
    var overlays = overlay_mod.OverlaySet(struct {
        adsb: adsb.AdsbOverlay = .{},
        ais: ais.AisOverlay = .{},
    }).init();

    // Pass DB handle to overlays so workers can persist data
    if (overlay_db) |*db| {
        overlays.overlays.ais.overlay_db = db;
        overlays.overlays.adsb.overlay_db = db;
    }

    // Load persisted overlay data immediately (before workers start)
    if (overlay_db) |*db| {
        const vc = db.loadAllVessels(&overlays.overlays.ais.vessels);
        overlays.overlays.ais.count = vc;
        const ac = db.loadAllAircraft(&overlays.overlays.adsb.aircraft);
        overlays.overlays.adsb.count = ac;
    }

    var photo_cache: photo_mod.PhotoCache = .{};
    if (overlay_db) |*db| photo_cache.overlay_db = db;
    photo_cache.start();
    defer photo_cache.shutdown();
    defer photo_cache.deinit();

    var selection: overlay_mod.Selection = .none;

    // Render performance timers
    var perf = perf_mod.PerfTimers{};

    while (!rl.windowShouldClose()) {
        const dt = rl.getFrameTime();
        const sw = rl.getScreenWidth();
        const sh = rl.getScreenHeight();

        // --- Live reload: check queue (lock-free pop, microseconds) ---
        if (queue.pop()) |result| {
            // Update attractor info
            if (result.num_attractors > 0) {
                nd.num_attractors = result.num_attractors;
                for (0..result.num_attractors) |i| {
                    nd.attractor_names[i] = result.attractor_name_indices[i];
                }
            }

            // Register any new names the worker discovered.
            // Sort by worker-assigned idx so main thread assigns identical indices.
            std.mem.sort(live.NameEntry, result.new_names.items, {}, struct {
                fn cmp(_: void, a: live.NameEntry, b: live.NameEntry) bool {
                    return a.idx < b.idx;
                }
            }.cmp);
            for (result.new_names.items) |ne| {
                _ = nd.getOrAddName(ne.synset, ne.word) catch continue;
            }
            // Merge new positions
            for (result.new_positions.items) |pe| {
                if (!nd.positions.contains(pe.name)) {
                    const arena = nd.string_arena.allocator();
                    const key = arena.dupe(u8, pe.name) catch continue;
                    nd.positions.put(key, pe.pos) catch {};
                }
            }

            // Copy points and timestamp to main-thread allocator so eviction can free them
            const points_copy = allocator.dupe(data.Point, result.keyframe.points) catch {
                var r = result;
                r.deinit();
                std.heap.page_allocator.destroy(r);
                continue;
            };
            const ts_copy = allocator.dupe(u8, result.keyframe.timestamp) catch {
                allocator.free(points_copy);
                var r = result;
                r.deinit();
                std.heap.page_allocator.destroy(r);
                continue;
            };
            var kf = result.keyframe;
            kf.points = points_copy;
            kf.timestamp = ts_copy;

            nd.keyframes.append(kf) catch {};

            // Time-based eviction: drop keyframes older than the timeline window
            tl.noteArrival(kf.wall_time);

            const cutoff = tl.windowStart();
            while (nd.keyframes.items.len > 1) {
                const oldest = nd.keyframes.items[0];
                const oldest_t: f64 = @floatFromInt(oldest.wall_time);
                if (oldest_t >= cutoff) break;
                _ = nd.keyframes.orderedRemove(0);
                allocator.free(oldest.points);
                allocator.free(@constCast(oldest.timestamp));
            }
            tl.noteEviction(nd.keyframes.items);

            // Clean up result (frees arena — we've copied what we need)
            var r = result;
            r.deinit();
            std.heap.page_allocator.destroy(r);
        }

        // Start playback from beginning once bootstrap is done
        if (queue.bootstrap_complete.load(.acquire) and tl.live and tl.earliest_time > 0) {
            tl.current_time = tl.earliest_time;
            tl.live = false;
            tl.playing = true;
        }

        // Check for navmesh path updates (separate from keyframe queue)
        if (queue.getNavPaths(&nav_version)) |paths| {
            nav_num_paths = paths.len;
            for (paths, 0..) |p, i| {
                nav_paths[i] = p;
            }
            // Mark that the paths we have now match what we last requested
            nav_attractor_hash = nav_requested_hash;
        }

        // Fit camera when first data arrives
        if (needs_camera_fit and nd.keyframes.items.len > 0) {
            const bounds = camera.computeBounds(nd.keyframes.items[nd.keyframes.items.len - 1].points);
            cam_state.bounds = bounds;
            cam_state.fitToScreen(sw, sh);
            needs_camera_fit = false;
        }

        // Input
        if (rl.isKeyPressed(rl.KEY_F11) or rl.isKeyPressed(rl.KEY_F)) {
            rl.toggleFullscreen();
        }
        fx.handleInput();
        perf.handleInput();
        overlays.handleToggles();
        if (search.active) {
            search.handleInput();
        } else {
            search.handleInput();
            tl.handleInput();
            cluster_filter.handleInput();
            // Clear selection if its cluster was just hidden
            if (cam_state.selected_point) |sel| {
                if (nd.keyframes.items.len > 0) {
                    const pts = nd.keyframes.items[nd.keyframes.items.len - 1].points;
                    if (sel < pts.len and !cluster_filter.isVisible(pts[sel].cluster)) {
                        cam_state.selected_point = null;
                    }
                }
            }
            if (rl.isKeyPressed(rl.KEY_G)) {
                phys.toggle();
            }
            if (rl.isKeyPressed(rl.KEY_N)) {
                navmesh_on = !navmesh_on;
                if (!navmesh_on) navmesh_focus = null;
            }
            if (rl.isKeyPressed(rl.KEY_ESCAPE)) {
                navmesh_focus = null;
                selection = .none;
            }
            if (rl.isKeyPressed(rl.KEY_E)) {
                edges_on = !edges_on;
            }
            if (rl.isKeyPressed(rl.KEY_M)) {
                phys.toggleGeo();
            }
            // ; / ' adjust geo spring strength
            if (phys.geo_active) {
                if (rl.isKeyPressed(rl.KEY_SEMICOLON)) {
                    phys.consts.geo_spring_k = @max(1.0, phys.consts.geo_spring_k - 2.0);
                }
                if (rl.isKeyPressed(rl.KEY_APOSTROPHE)) {
                    phys.consts.geo_spring_k = @min(100.0, phys.consts.geo_spring_k + 2.0);
                }
            }
            // Double-click on land: zoom to region (must run before camera.update)
            if (wmap) |*m| m.handleInput(&cam_state, sw, sh);
        }
        tl.update(dt);

        // --- Drawing ---
        // Ensure effects textures match window size
        fx.handleResize(sw, sh);

        const keyframes = nd.keyframes.items;
        if (keyframes.len == 0) {
            // Loading screen — direct to screen, no effects
            rl.beginDrawing();
            rl.clearBackground(constants.BG_COLOR);
            rl.drawTextEx(font, "CASSANDRA", rl.vec2(20, 20), 24, 2.0, constants.HUD_COLOR);
            rl.drawTextEx(font, "WordNet Nucleus Observer", rl.vec2(20, 52), 11, 1.0, constants.HUD_DIM);
            rl.drawTextEx(font, "Loading snapshots...", rl.vec2(20, 72), 14, 1.0, constants.HUD_DIM);
            rl.drawFPS(sw - 90, sh - 60);
            rl.endDrawing();
            continue;
        }

        // Begin scene: if effects active, render to texture; otherwise direct to screen
        if (fx.anyActive()) {
            fx.beginScene();
        } else {
            rl.beginDrawing();
            rl.clearBackground(constants.BG_COLOR);
        }

        const bracket = tl.findBracket(keyframes);
        const ki = bracket.a;
        const frac = bracket.frac;

        const current_points: []const data.Point = blk: {
            if (frac < 0.01 or bracket.a == bracket.b) {
                break :blk keyframes[ki].points;
            } else {
                if (interp_buf) |buf| allocator.free(buf);
                interp_buf = try timeline_mod.lerpPoints(
                    keyframes[bracket.a].points,
                    keyframes[bracket.b].points,
                    frac,
                    allocator,
                );
                break :blk interp_buf.?;
            }
        };

        const cur_kf = keyframes[ki];

        // --- Physics integration ---
        if (phys.isActive()) {
            if (ki != prev_ki) {
                try phys.syncToPoints(current_points, cur_kf.max_delta);
                prev_ki = ki;
            } else {
                const md = @max(cur_kf.max_delta, 1.0);
                for (current_points, 0..) |p, idx| {
                    if (idx < phys.count and phys.name_indices[idx] == p.name_idx) {
                        phys.activity[idx] = p.delta / md;
                    }
                }
            }
            // Populate geo targets: exact position if available, else spread within country bbox
            if (wmap) |*m| {
                for (0..phys.count) |i| {
                    const ni = phys.name_indices[i];
                    if (m.point_geo[ni]) |geo| {
                        // Exact position from geo_places table
                        phys.geo_x[i] = geo[0];
                        phys.geo_y[i] = geo[1];
                        phys.has_geo[i] = true;
                    } else if (m.point_region[ni]) |ri| {
                        // Deterministic spread within country bbox
                        const seed: u32 = @as(u32, ni) *% 2654435761; // Knuth multiplicative hash
                        const sx = @as(f32, @floatFromInt(seed & 0xFFFF)) / 65536.0 * 2.0 - 1.0; // -1..1
                        const sy = @as(f32, @floatFromInt((seed >> 16) & 0xFFFF)) / 65536.0 * 2.0 - 1.0;
                        phys.geo_x[i] = m.spread_cx[ri] + sx * m.spread_hw[ri];
                        phys.geo_y[i] = m.spread_cy[ri] + sy * m.spread_hh[ri];
                        phys.has_geo[i] = true;
                    } else {
                        phys.has_geo[i] = false;
                    }
                }
            }
            phys.step(dt);
            phys.updateBlend(dt);
            phys.updateGeo(dt);

            if (phys_buf) |buf| allocator.free(buf);
            phys_buf = try allocator.alloc(data.Point, current_points.len);
            @memcpy(phys_buf.?, current_points);
            phys.applyToPoints(phys_buf.?);
        } else {
            phys.updateBlend(dt);
            phys.updateGeo(dt);
        }

        const render_points: []const data.Point = if (phys.isActive())
            phys_buf.?
        else
            current_points;

        // --- Build BVH and compute visible set ---
        frame_bvh.buildFromPoints(render_points);

        // Get viewport world bounds (with margin for labels/glow)
        const margin_px: f32 = 60.0; // pixels of margin for glow/labels that extend past viewport
        const top_left = rl.getScreenToWorld2D(rl.vec2(-margin_px, -margin_px), cam_state.cam);
        const bot_right = rl.getScreenToWorld2D(rl.vec2(
            @as(f32, @floatFromInt(sw)) + margin_px,
            @as(f32, @floatFromInt(sh)) + margin_px,
        ), cam_state.cam);

        var viewport_iter = frame_bvh.bvh.queryAABB(top_left.x, top_left.y, bot_right.x, bot_right.y);
        var n_visible: usize = 0;
        while (viewport_iter.next()) |idx| {
            if (n_visible >= bvh.MAX_POINTS) break;
            visible_buf[n_visible] = idx;
            n_visible += 1;
        }
        const visible = visible_buf[0..n_visible];

        cam_state.update(render_points, sw, sh, &frame_bvh, &cluster_filter);

        // Unified click routing: test overlay hits alongside concept hits
        if (rl.isMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) {
            const mouse_pos = rl.getMousePosition();
            if (mouse_pos.y < @as(f32, @floatFromInt(sh)) - 50) {
                const world_pos = rl.getScreenToWorld2D(mouse_pos, cam_state.cam);
                const overlay_hit = overlays.hitTest(world_pos, cam_state.cam.zoom);

                if (cam_state.selected_point) |concept_idx| {
                    // Camera found a concept point — compare with overlay hit
                    if (overlay_hit) |oh| {
                        // Compute concept dist_sq
                        const cp = render_points[concept_idx];
                        const cdx = world_pos.x - cp.x;
                        const cdy = world_pos.y - cp.y;
                        const concept_dist = cdx * cdx + cdy * cdy;
                        if (oh.dist_sq < concept_dist) {
                            // Overlay is closer
                            selection = .{ .overlay = oh };
                            cam_state.selected_point = null;
                        } else {
                            selection = .{ .concept = concept_idx };
                        }
                    } else {
                        selection = .{ .concept = concept_idx };
                    }
                } else {
                    // No concept hit
                    if (overlay_hit) |oh| {
                        selection = .{ .overlay = oh };
                    } else {
                        selection = .none;
                    }
                }
            }
        }
        // Keep cam_state.selected_point synced with selection for highlight ring
        // Also detect when camera cleared selection (ESC/HOME) and propagate
        if (cam_state.selected_point == null) {
            switch (selection) {
                .concept => selection = .none,
                else => {},
            }
        }
        switch (selection) {
            .concept => |idx| cam_state.selected_point = idx,
            .overlay => cam_state.selected_point = null,
            .none => {},
        }
        // Clear overlay selection if its overlay was toggled off
        switch (selection) {
            .overlay => |hit| {
                if (!overlays.isEnabled(hit.overlay_idx)) {
                    selection = .none;
                }
            },
            else => {},
        }

        // Update navmesh focus on click: clicking an attractor focuses paths from it
        if (navmesh_on and rl.isMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) {
            // Check if the just-selected point is an attractor
            if (cam_state.selected_point) |sel| {
                if (sel < render_points.len and render_points[sel].is_attractor) {
                    const clicked_name = render_points[sel].name_idx;
                    if (navmesh_focus) |current| {
                        navmesh_focus = if (current == clicked_name) null else clicked_name;
                    } else {
                        navmesh_focus = clicked_name;
                    }
                }
            } else {
                navmesh_focus = null; // clicked empty space
            }
        }

        // Auto-focus navmesh on selected attractor (e.g. toggling N with attractor already selected)
        if (navmesh_on and navmesh_focus == null) {
            if (cam_state.selected_point) |sel| {
                if (sel < render_points.len and render_points[sel].is_attractor) {
                    navmesh_focus = render_points[sel].name_idx;
                }
            }
        }

        // Recompute navmesh paths when the displayed attractor set changes (timeline scrub)
        {
            const AttPair = struct { idx: u16, cluster: u8 };
            var att_pairs: [constants.NUM_ATTRACTORS]AttPair = undefined;
            var n_att: usize = 0;
            for (render_points) |p| {
                if (p.is_attractor and n_att < constants.NUM_ATTRACTORS) {
                    att_pairs[n_att] = .{ .idx = p.name_idx, .cluster = p.cluster };
                    n_att += 1;
                }
            }
            if (n_att > 0) {
                // Sort by name_idx so hash is order-independent
                std.mem.sort(AttPair, att_pairs[0..n_att], {}, struct {
                    fn cmp(_: void, a: AttPair, b: AttPair) bool {
                        return a.idx < b.idx;
                    }
                }.cmp);
                var att_buf: [constants.NUM_ATTRACTORS]u16 = undefined;
                var att_clusters: [constants.NUM_ATTRACTORS]u8 = undefined;
                for (att_pairs[0..n_att], 0..) |ap, i| {
                    att_buf[i] = ap.idx;
                    att_clusters[i] = ap.cluster;
                }
                const cur_hash = hashAttractors(att_buf[0..n_att]);
                if (cur_hash != nav_attractor_hash and cur_hash != nav_requested_hash) {
                    nav_requested_hash = cur_hash;
                    // Request async navmesh recomputation from worker thread
                    queue.requestNavPaths(att_buf[0..n_att], att_clusters[0..n_att]);
                }
            }
        }

        // Update region heat from nucleus activity
        if (wmap) |*m| m.updateHeat(render_points, &nd, cur_kf.max_delta);

        // Build FrameContext for overlays
        const fctx = overlay_mod.FrameContext{
            .render_points = render_points,
            .nd = &nd,
            .cur_kf = cur_kf,
            .cam = cam_state.cam,
            .sw = sw,
            .sh = sh,
            .visible = visible,
            .wmap = if (wmap) |*m| m else null,
            .cluster_filter = &cluster_filter,
            .dt = dt,
            .font = font,
            .allocator = allocator,
            .photo_cache = &photo_cache,
            .overlay_db = if (overlay_db) |*db| db else null,
        };

        // Update overlay state (drain pending data from worker threads)
        overlays.update(&fctx);
        photo_cache.processCompleted();

        rl.beginMode2D(cam_state.cam);

        perf.lapStart();
        render.drawGrid(cam_state.cam, sw, sh);
        perf.lapEnd(perf_mod.GRID);

        perf.lapStart();
        if (wmap) |*m| m.draw(cam_state.cam, sw, sh);
        perf.lapEnd(perf_mod.MAP);

        perf.lapStart();
        if (navmesh_on and nav_num_paths > 0) {
            render.drawNavmesh(render_points, nav_paths[0..nav_num_paths], &cluster_filter, navmesh_focus);
        }
        perf.lapEnd(perf_mod.NAVMESH);

        perf.lapStart();
        if (edges_on) render.drawConnectionLines(render_points, &cluster_filter, visible);
        render.drawDots(render_points, cur_kf.max_total, cur_kf.max_delta, &cluster_filter, visible);
        render.drawAttractorRings(render_points, &cluster_filter, visible);
        if (cam_state.selected_point) |sel| {
            render.drawHighlight(render_points, sel);
        }
        if (search.len > 0) {
            render.drawSearchHighlights(render_points, &nd, search.query(), visible);
        }
        perf.lapEnd(perf_mod.DOTS);

        perf.lapStart();
        render.drawGlow(render_points, cur_kf.max_delta, &cluster_filter, visible);
        perf.lapEnd(perf_mod.GLOW);

        // Overlay world-space drawing (inside Mode2D)
        perf.lapStart();
        overlays.drawWorld(&fctx);
        perf.lapEnd(perf_mod.OVERLAYS);

        rl.endMode2D();

        // End scene: composite effects (trails/bloom), then draw overlays on top
        perf.lapStart();
        if (fx.anyActive()) {
            fx.endScene();
        }
        perf.lapEnd(perf_mod.EFFECTS);

        // Labels, vignette, and HUD drawn AFTER effects so they stay crisp
        perf.lapStart();
        if (wmap) |*m| {
            rl.beginMode2D(cam_state.cam);
            m.drawLabels(cam_state.cam, font);
            rl.endMode2D();
        }
        render.drawLabels(render_points, &nd, cam_state.cam, font, &cluster_filter, cur_kf.max_delta, visible);
        if (navmesh_on and navmesh_focus != null) {
            render.drawNavmeshLabels(render_points, &nd, cam_state.cam, font);
        }
        perf.lapEnd(perf_mod.LABELS);

        // Overlay screen-space drawing
        overlays.drawScreen(&fctx);

        render.drawVignette(sw, sh);
        if (wmap) |*m| m.drawSelectedHeading(font, sw);
        ui.drawHUD(font, cur_kf.timestamp, cur_kf.num_visible, cur_kf.num_hot, @intCast(keyframes.len), &tl, phys.isActive(), keyframes);
        ui.drawScrubber(&tl, font, sw, sh, keyframes);
        ui.drawClusterFilter(&cluster_filter, sw);
        ui.drawSearchBar(&search, font, sw);

        switch (selection) {
            .concept => |idx| ui.drawDetailPanel(render_points, idx, &nd, font, sw),
            .overlay => |hit| overlays.drawDetail(&fctx, hit),
            .none => {},
        }

        // Effects status indicator
        {
            var fx_buf: [128]u8 = undefined;
            var fx_len: usize = 0;
            if (fx.trails_on or fx.bloom_on or navmesh_on or !edges_on or phys.geo_active or
                overlays.overlays.adsb.active or overlays.overlays.ais.active)
            {
                @memcpy(fx_buf[0..4], "FX: ");
                fx_len = 4;
                if (fx.trails_on) {
                    @memcpy(fx_buf[fx_len..][0..6], "TRAILS");
                    fx_len += 6;
                }
                if (fx.bloom_on) {
                    if (fx_len > 4) {
                        @memcpy(fx_buf[fx_len..][0..3], " + ");
                        fx_len += 3;
                    }
                    @memcpy(fx_buf[fx_len..][0..5], "BLOOM");
                    fx_len += 5;
                }
                if (navmesh_on) {
                    if (fx_len > 4) {
                        @memcpy(fx_buf[fx_len..][0..3], " + ");
                        fx_len += 3;
                    }
                    @memcpy(fx_buf[fx_len..][0..7], "NAVMESH");
                    fx_len += 7;
                }
                if (!edges_on) {
                    if (fx_len > 4) {
                        @memcpy(fx_buf[fx_len..][0..3], " + ");
                        fx_len += 3;
                    }
                    @memcpy(fx_buf[fx_len..][0..8], "NO EDGES");
                    fx_len += 8;
                }
                if (phys.geo_active) {
                    if (fx_len > 4) {
                        @memcpy(fx_buf[fx_len..][0..3], " + ");
                        fx_len += 3;
                    }
                    @memcpy(fx_buf[fx_len..][0..4], "GEO ");
                    fx_len += 4;
                    const k_int: u32 = @intFromFloat(phys.consts.geo_spring_k);
                    const k_frac: u32 = @intFromFloat((phys.consts.geo_spring_k - @as(f32, @floatFromInt(k_int))) * 10 + 0.5);
                    if (k_int >= 10) {
                        fx_buf[fx_len] = '0' + @as(u8, @intCast(k_int / 10));
                        fx_len += 1;
                    }
                    fx_buf[fx_len] = '0' + @as(u8, @intCast(k_int % 10));
                    fx_len += 1;
                    fx_buf[fx_len] = '.';
                    fx_len += 1;
                    fx_buf[fx_len] = '0' + @as(u8, @intCast(k_frac % 10));
                    fx_len += 1;
                }
                // Append overlay status text
                {
                    var tmp_buf: [32]u8 = undefined;
                    const overlay_status = overlays.statusText(&tmp_buf);
                    if (overlay_status > 0) {
                        if (fx_len > 4) {
                            @memcpy(fx_buf[fx_len..][0..3], " + ");
                            fx_len += 3;
                        }
                        @memcpy(fx_buf[fx_len..][0..overlay_status], tmp_buf[0..overlay_status]);
                        fx_len += overlay_status;
                    }
                }
                fx_buf[fx_len] = 0;
                const text: [*:0]const u8 = @ptrCast(&fx_buf);
                rl.drawTextEx(font, text, rl.vec2(10, @as(f32, @floatFromInt(sh)) - 30), 10, 1.0, constants.HUD_DIM);
            }
        }

        perf.endFrame();
        perf.draw(font, sw, sh);

        rl.drawFPS(sw - 90, sh - 60);
        rl.endDrawing();
    }
}

/// Simple hash of an attractor name_idx slice to detect changes.
fn hashAttractors(indices: []const u16) u64 {
    var h: u64 = 0xcbf29ce484222325; // FNV-1a offset basis
    for (indices) |idx| {
        h ^= @as(u64, idx);
        h *%= 0x100000001b3; // FNV-1a prime
    }
    return h;
}
