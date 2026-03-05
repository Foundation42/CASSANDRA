const std = @import("std");
const data = @import("data.zig");
const constants = @import("constants.zig");
const db_mod = @import("db.zig");

/// A fully-built keyframe ready for the main thread to append.
pub const ReadyKeyframe = struct {
    keyframe: data.Keyframe,
    timestamp: []const u8,
    // New names the main thread needs to register (worker may have seen new nuclei)
    new_names: std.ArrayList(NameEntry),
    // New positions
    new_positions: std.ArrayList(PosEntry),
    // Attractor info for main thread to update nd
    attractor_name_indices: [constants.NUM_ATTRACTORS]u16,
    num_attractors: usize,

    pub fn deinit(self: *ReadyKeyframe) void {
        self.new_names.deinit();
        self.new_positions.deinit();
    }
};

pub const NameEntry = struct {
    synset: []const u8,
    word: []const u8,
    idx: u16,
};

pub const PosEntry = struct {
    name: []const u8,
    pos: [2]f32,
};

/// Thread-safe queue: worker pushes, main thread pops.
/// Protected by a mutex — held only briefly for pointer swap.
pub const LiveQueue = struct {
    mutex: std.Thread.Mutex = .{},
    ready: ?*ReadyKeyframe = null,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    pub fn pop(self: *LiveQueue) ?*ReadyKeyframe {
        self.mutex.lock();
        defer self.mutex.unlock();
        const r = self.ready;
        self.ready = null;
        return r;
    }

    pub fn requestShutdown(self: *LiveQueue) void {
        self.shutdown.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn spawn(
        self: *LiveQueue,
        nd_snapshot: *const NdSnapshot,
    ) void {
        self.thread = std.Thread.spawn(.{}, workerLoop, .{ self, nd_snapshot }) catch return;
    }
};

/// Read-only snapshot of NucleusData that the worker thread uses.
/// Built once at startup, never modified by main thread after spawn.
pub const NdSnapshot = struct {
    positions: std.StringHashMap([2]f32),
    anchors: std.StringHashMap([constants.ANCHOR_DIM]f32),
    name_to_idx: std.StringHashMap(u16),
    next_idx: u16,
    // Worker's running recency: nucleus name → wall-time of last activity (seconds)
    recency: std.StringHashMap(i64),

    pub fn init(nd: *data.NucleusData, initial_recency: *std.StringHashMap(i64)) NdSnapshot {
        return .{
            .positions = nd.positions,
            .anchors = nd.anchors,
            .name_to_idx = nd.name_to_idx,
            .next_idx = @intCast(nd.synset_names.items.len),
            .recency = initial_recency.*,
        };
    }
};

fn workerLoop(
    queue: *LiveQueue,
    nds: *const NdSnapshot,
) void {
    const page = std.heap.page_allocator;

    // Worker's mutable state
    var positions = nds.positions;
    var anchors = nds.anchors;
    var name_to_idx = nds.name_to_idx;
    var next_idx = nds.next_idx;
    var last_reported_idx: u16 = nds.next_idx;
    var recency = nds.recency;
    var prev_snap: ?std.StringHashMap(data.SnapshotEntry) = null;

    // Attractor state
    var attractor_synsets: []const []const u8 = &.{};
    var attractor_labels: []const u8 = &.{};
    var attractor_name_indices: [constants.NUM_ATTRACTORS]u16 = .{0} ** constants.NUM_ATTRACTORS;
    var num_attractors: usize = 0;

    const x_scale: f32 = @as(f32, @floatFromInt(constants.WINDOW_W)) / @as(f32, @floatFromInt(constants.WINDOW_H));

    // --- Open database ---
    var database = db_mod.Db.open("../nucleus.db") catch {
        std.debug.print("Worker: failed to open nucleus.db\n", .{});
        return;
    };
    defer database.close();
    std.debug.print("Worker: opened nucleus.db\n", .{});

    // --- Load all nuclei (anchors + name_to_idx + display words) ---
    var synset_to_word = std.StringHashMap([]const u8).init(page);
    {
        var nuclei_list = database.getAllNuclei(page) catch {
            std.debug.print("Worker: failed to load nuclei\n", .{});
            return;
        };
        std.debug.print("Worker: loaded {d} nuclei\n", .{nuclei_list.items.len});

        for (nuclei_list.items) |row| {
            if (!anchors.contains(row.synset)) {
                anchors.put(row.synset, row.anchor) catch {};
            }
            if (!name_to_idx.contains(row.synset)) {
                name_to_idx.put(row.synset, next_idx) catch {};
                next_idx += 1;
            }
            synset_to_word.put(row.synset, row.word) catch {};
        }
        nuclei_list.deinit();
    }

    // --- Load all positions ---
    {
        var pos_list = database.getAllPositions(page) catch {
            std.debug.print("Worker: failed to load positions\n", .{});
            return;
        };
        std.debug.print("Worker: loaded {d} positions\n", .{pos_list.items.len});

        for (pos_list.items) |row| {
            if (!positions.contains(row.synset)) {
                positions.put(row.synset, .{ row.x, row.y }) catch {};
            }
        }
        pos_list.deinit();
    }

    // --- Determine attractors from final snapshot observation counts ---
    // We'll determine attractors after processing the first snapshot (or the latest)
    // For now, bootstrap through all snapshots and determine attractors along the way.

    // Arena for prev_snap lifetime management
    var prev_arena: ?std.heap.ArenaAllocator = null;
    var last_snapshot_id: i64 = 0;
    var bootstrapping = true;
    var boot_count: u32 = 0;

    // Bootstrap: list all snapshot IDs
    var boot_stmt = database.listSnapshotIds() catch {
        std.debug.print("Worker: failed to list snapshots\n", .{});
        return;
    };
    defer boot_stmt.finalize();

    while (!queue.shutdown.load(.acquire)) {
        // Try to get next snapshot — either from bootstrap or live poll
        var snap_id: i64 = 0;
        var snap_ts_raw: ?[]const u8 = null;
        var snap_wall_time: i64 = 0;

        if (bootstrapping) {
            if (boot_stmt.step()) {
                snap_id = boot_stmt.columnInt(0);
                snap_ts_raw = boot_stmt.columnText(1);
                snap_wall_time = boot_stmt.columnInt(2);
            } else {
                bootstrapping = false;
                std.debug.print("Worker: bootstrap complete ({d} snapshots)\n", .{boot_count});
                continue;
            }
        } else {
            // Live poll: sleep then check for new snapshots
            std.time.sleep(2 * std.time.ns_per_s);
            if (queue.shutdown.load(.acquire)) break;

            const poll_stmt = database.getSnapshotsAfter(last_snapshot_id);
            if (poll_stmt.step()) {
                snap_id = poll_stmt.columnInt(0);
                snap_ts_raw = poll_stmt.columnText(1);
                snap_wall_time = poll_stmt.columnInt(2);
            } else {
                continue;
            }
        }

        const ts_raw = snap_ts_raw orelse continue;

        // Wait for slot to be free
        {
            queue.mutex.lock();
            const has_pending = queue.ready != null;
            queue.mutex.unlock();
            if (has_pending) {
                std.time.sleep(10 * std.time.ns_per_ms);
                // For bootstrap, we need to re-step; for live, we'll retry next loop
                continue;
            }
        }

        // Allocate arena for this snapshot's data
        var arena = std.heap.ArenaAllocator.init(page);
        const alloc = arena.allocator();

        const ts_copy = alloc.dupe(u8, ts_raw) catch continue;
        const wall_time = snap_wall_time;

        // Read observations for this snapshot
        var snapshot_map = std.StringHashMap(data.SnapshotEntry).init(alloc);
        var delta_map = std.StringHashMap(i64).init(alloc);

        {
            const obs_stmt = database.getObservations(snap_id);
            while (obs_stmt.step()) {
                const synset_raw = obs_stmt.columnText(0) orelse continue;
                const update_count = obs_stmt.columnInt(1);
                const exemplar_count = obs_stmt.columnInt(2);
                const uncertainty = obs_stmt.columnDouble(3);
                const delta_val = obs_stmt.columnInt(4);

                const synset = alloc.dupe(u8, synset_raw) catch continue;

                // Register name index if new
                if (!name_to_idx.contains(synset_raw)) {
                    const persist_key = page.dupe(u8, synset_raw) catch continue;
                    name_to_idx.put(persist_key, next_idx) catch {};
                    next_idx += 1;
                }

                const word = synset_to_word.get(synset_raw) orelse synset;
                snapshot_map.put(synset, .{
                    .word = word,
                    .update_count = update_count,
                    .exemplar_count = exemplar_count,
                    .uncertainty = uncertainty,
                    .anchor = undefined,
                }) catch {};

                if (delta_val > 0) {
                    delta_map.put(synset, delta_val) catch {};
                }
            }
        }

        // Update recency
        {
            var dk_it = delta_map.iterator();
            while (dk_it.next()) |d_entry| {
                if (!recency.contains(d_entry.key_ptr.*)) {
                    const key = page.dupe(u8, d_entry.key_ptr.*) catch continue;
                    recency.put(key, wall_time) catch {};
                } else {
                    recency.put(d_entry.key_ptr.*, wall_time) catch {};
                }
            }
            // Evict nuclei inactive for > 2x the fade window
            const evict_threshold: i64 = @intFromFloat(constants.FADE_SECONDS * 2);
            var remove_list = std.ArrayList([]const u8).init(alloc);
            var rm_it = recency.iterator();
            while (rm_it.next()) |entry| {
                if (wall_time - entry.value_ptr.* > evict_threshold) {
                    remove_list.append(entry.key_ptr.*) catch {};
                }
            }
            for (remove_list.items) |key| {
                _ = recency.remove(key);
            }
        }

        // Determine attractors from the running snapshot_map
        // (On bootstrap, the last snapshot's counts are the cumulative counts)
        {
            const raw_att = data.findAttractors(&snapshot_map, alloc) catch &.{};
            if (raw_att.len > 0) {
                // Dupe attractor names to persistent allocator
                if (page.alloc([]const u8, raw_att.len)) |buf| {
                    var ok = true;
                    for (raw_att, 0..) |name, i| {
                        buf[i] = page.dupe(u8, name) catch {
                            ok = false;
                            break;
                        };
                    }
                    if (ok) attractor_synsets = buf;
                } else |_| {}

                const k: u8 = @intCast(@min(constants.NUM_CLUSTERS, attractor_synsets.len));
                attractor_labels = data.kmeansAttractors(attractor_synsets, &anchors, k, page) catch &.{};
                num_attractors = attractor_synsets.len;
            }
        }

        // Build keyframe
        const kf = buildKeyframeWorker(
            alloc,
            &positions,
            &anchors,
            &name_to_idx,
            &snapshot_map,
            &delta_map,
            &recency,
            if (prev_snap) |*ps| ps else null,
            attractor_synsets,
            attractor_labels,
            ts_copy,
            wall_time,
            x_scale,
        ) catch continue;

        // Collect new names added since last push
        var new_names = std.ArrayList(NameEntry).init(alloc);
        var nm_it = name_to_idx.iterator();
        while (nm_it.next()) |entry| {
            if (entry.value_ptr.* >= last_reported_idx) {
                const synset_copy = alloc.dupe(u8, entry.key_ptr.*) catch continue;
                const word = synset_to_word.get(entry.key_ptr.*) orelse entry.key_ptr.*;
                const word_copy = alloc.dupe(u8, word) catch continue;
                new_names.append(.{
                    .synset = synset_copy,
                    .word = word_copy,
                    .idx = entry.value_ptr.*,
                }) catch {};
            }
        }
        last_reported_idx = next_idx;

        // Update attractor name indices
        for (attractor_synsets, 0..) |aname, i| {
            attractor_name_indices[i] = name_to_idx.get(aname) orelse 0;
        }

        // New positions (report all positions not yet known to main thread)
        const new_positions = std.ArrayList(PosEntry).init(alloc);
        // We load positions once at startup; new_positions is for any that appeared
        // during this cycle. Since we loaded all from DB, this is typically empty.

        // Free prev_snap arena
        if (prev_snap) |*ps| ps.deinit();
        if (prev_arena) |*pa| pa.deinit();
        prev_snap = snapshot_map;
        prev_arena = arena;

        // Build result
        const result = page.create(ReadyKeyframe) catch continue;
        result.* = .{
            .keyframe = kf,
            .timestamp = ts_copy,
            .new_names = new_names,
            .new_positions = new_positions,
            .attractor_name_indices = attractor_name_indices,
            .num_attractors = num_attractors,
        };

        // Push to queue
        {
            queue.mutex.lock();
            defer queue.mutex.unlock();
            queue.ready = result;
        }

        last_snapshot_id = snap_id;

        if (bootstrapping) {
            boot_count += 1;
            if (boot_count % 100 == 0) {
                std.debug.print("  Bootstrap: {d} snapshots loaded\n", .{boot_count});
            }
        } else {
            std.debug.print("Live: prepared {s} ({d} points)\n", .{ ts_copy, kf.points.len });
        }
    }
}

fn buildKeyframeWorker(
    alloc: std.mem.Allocator,
    positions: *const std.StringHashMap([2]f32),
    anchors: *const std.StringHashMap([constants.ANCHOR_DIM]f32),
    name_to_idx: *const std.StringHashMap(u16),
    snapshot: *std.StringHashMap(data.SnapshotEntry),
    delta: *std.StringHashMap(i64),
    recency: *std.StringHashMap(i64),
    prev_snapshot: ?*std.StringHashMap(data.SnapshotEntry),
    attractor_synsets: []const []const u8,
    attractor_labels: []const u8,
    timestamp: []const u8,
    wall_time: i64,
    x_scale: f32,
) !data.Keyframe {
    var points = std.ArrayList(data.Point).init(alloc);
    var max_delta: f32 = 1;
    var max_total: f32 = 1;
    var num_hot: u32 = 0;

    var pos_it = positions.iterator();
    while (pos_it.next()) |pos_entry| {
        const name = pos_entry.key_ptr.*;
        const pos = pos_entry.value_ptr.*;

        const snap_entry = snapshot.get(name) orelse continue;
        if (snap_entry.update_count == 0) continue;

        const last_active: i64 = recency.get(name) orelse 0;
        if (last_active == 0) continue;
        const age_secs: f64 = @floatFromInt(wall_time - last_active);
        if (age_secs > constants.FADE_SECONDS) continue;

        const fade: f32 = @floatCast(1.0 - (age_secs / constants.FADE_SECONDS));
        const d: f32 = @floatFromInt(delta.get(name) orelse 0);
        const total: f32 = @floatFromInt(snap_entry.update_count);

        var u_shift: f32 = 0;
        if (prev_snapshot) |prev| {
            if (prev.get(name)) |prev_e| {
                u_shift = @as(f32, @floatCast(snap_entry.uncertainty)) - @as(f32, @floatCast(prev_e.uncertainty));
            }
        }

        const cluster_info = data.assignAllClusters(name, attractor_synsets, attractor_labels, anchors);

        var is_att = false;
        for (attractor_synsets) |aname| {
            if (std.mem.eql(u8, name, aname)) {
                is_att = true;
                break;
            }
        }

        const name_idx = name_to_idx.get(name) orelse continue;

        if (d > max_delta) max_delta = d;
        if (total > max_total) max_total = total;
        if (d > 0) num_hot += 1;

        try points.append(.{
            .name_idx = name_idx,
            .x = pos[0] * x_scale,
            .y = pos[1],
            .total = total,
            .exemplars = @floatFromInt(snap_entry.exemplar_count),
            .delta = d,
            .uncertainty = @floatCast(snap_entry.uncertainty),
            .u_shift = u_shift,
            .fade = fade,
            .cluster = cluster_info.cluster,
            .is_attractor = is_att,
            .nearest_attractor = cluster_info.nearest,
        });
    }

    const num_visible: u32 = @intCast(points.items.len);
    return .{
        .timestamp = timestamp,
        .points = try points.toOwnedSlice(),
        .max_delta = max_delta,
        .max_total = max_total,
        .num_hot = num_hot,
        .num_visible = num_visible,
        .wall_time = wall_time,
    };
}
