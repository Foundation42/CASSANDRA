const std = @import("std");
const data = @import("data.zig");
const constants = @import("constants.zig");

/// A fully-built keyframe ready for the main thread to append.
pub const ReadyKeyframe = struct {
    keyframe: data.Keyframe,
    timestamp: []const u8,
    // New names the main thread needs to register (worker may have seen new nuclei)
    new_names: std.ArrayList(NameEntry),
    // New positions
    new_positions: std.ArrayList(PosEntry),
    // Delta map for recency update
    delta_keys: std.ArrayList([]const u8),
    // Arena that owns all string data in this result
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ReadyKeyframe) void {
        self.new_names.deinit();
        self.new_positions.deinit();
        self.delta_keys.deinit();
        // Don't deinit arena — main thread takes ownership of strings
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

    // Immutable config set once before spawning
    attractor_synsets: []const []const u8 = &.{},
    attractor_labels: []const u8 = &.{},
    x_scale: f32 = 1.0,

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
        initial_timestamps: []const []const u8,
        nd_snapshot: *const NdSnapshot,
    ) void {
        self.thread = std.Thread.spawn(.{}, workerLoop, .{ self, initial_timestamps, nd_snapshot }) catch return;
    }
};

/// Read-only snapshot of NucleusData that the worker thread uses.
/// Built once at startup, never modified by main thread after spawn.
pub const NdSnapshot = struct {
    positions: std.StringHashMap([2]f32),
    anchors: std.StringHashMap([constants.ANCHOR_DIM]f32),
    name_to_idx: std.StringHashMap(u16),
    next_idx: u16,
    // Worker's running recency
    recency: std.StringHashMap(u32),

    pub fn init(nd: *data.NucleusData, initial_recency: *std.StringHashMap(u32)) NdSnapshot {
        // These are shallow copies — they share arena-allocated key strings with nd.
        // That's safe because arena strings are never freed individually.
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
    initial_timestamps: []const []const u8,
    nds: *const NdSnapshot,
) void {
    const page = std.heap.page_allocator;

    // Worker's own copy of known timestamps
    var known = std.StringHashMap(void).init(page);
    for (initial_timestamps) |ts| {
        known.put(ts, {}) catch {};
    }

    // Worker's mutable copy of NdSnapshot data
    var positions = nds.positions;
    var anchors = nds.anchors;
    var name_to_idx = nds.name_to_idx;
    var next_idx = nds.next_idx;
    var recency = nds.recency;

    // Track prev_snapshot for uncertainty shift computation
    var prev_snap: ?std.StringHashMap(data.SnapshotEntry) = null;

    while (!queue.shutdown.load(.acquire)) {
        // Sleep between scans
        std.time.sleep(2 * std.time.ns_per_s);
        if (queue.shutdown.load(.acquire)) break;

        // Don't produce if main thread hasn't consumed yet
        {
            queue.mutex.lock();
            const has_pending = queue.ready != null;
            queue.mutex.unlock();
            if (has_pending) continue;
        }

        // Scan for first unknown snapshot
        const ts_buf = findNewTimestamp(&known) orelse continue;
        const ts = ts_buf.ts[0..ts_buf.len];

        // Read and parse
        var arena = std.heap.ArenaAllocator.init(page);
        const alloc = arena.allocator();

        const snap_path = std.fmt.allocPrint(alloc, "../snapshots/snap_{s}.json", .{ts}) catch continue;
        const delta_path = std.fmt.allocPrint(alloc, "../snapshots/delta_{s}.json", .{ts}) catch continue;

        // Read files
        const snap_bytes = readFile(alloc, snap_path) catch continue;
        const delta_bytes = readFile(alloc, delta_path) catch continue;
        const pos_bytes = readFile(alloc, "../nucleus_positions.json") catch null;

        // Parse positions (merge new ones)
        var new_positions = std.ArrayList(PosEntry).init(alloc);
        if (pos_bytes) |pb| {
            parseAndMergePositions(alloc, pb, &positions, &new_positions) catch {};
        }

        // Parse snapshot
        var snapshot_map = parseSnapshot(alloc, snap_bytes, &anchors, &name_to_idx, &next_idx) catch continue;
        var new_names = std.ArrayList(NameEntry).init(alloc);
        // Collect new name entries
        var snap_it = snapshot_map.iterator();
        while (snap_it.next()) |entry| {
            // Check if this is a new name the main thread doesn't know about
            // (name_to_idx was cloned from nd, so new entries are worker-only)
            _ = entry;
        }

        // Parse delta
        var delta_map = parseDelta(alloc, delta_bytes) catch std.StringHashMap(i64).init(alloc);

        // Update recency
        var age_it = recency.iterator();
        while (age_it.next()) |entry| {
            entry.value_ptr.* += 1;
        }
        var delta_keys = std.ArrayList([]const u8).init(alloc);
        var dk_it = delta_map.iterator();
        while (dk_it.next()) |d_entry| {
            const key = alloc.dupe(u8, d_entry.key_ptr.*) catch continue;
            recency.put(key, 0) catch {};
            delta_keys.append(d_entry.key_ptr.*) catch {};
        }
        // Evict old
        const evict_threshold: u32 = @intFromFloat(constants.FADE_WINDOW * 2);
        {
            var remove_list = std.ArrayList([]const u8).init(alloc);
            var rm_it = recency.iterator();
            while (rm_it.next()) |entry| {
                if (entry.value_ptr.* > evict_threshold) {
                    remove_list.append(entry.key_ptr.*) catch {};
                }
            }
            for (remove_list.items) |key| {
                _ = recency.remove(key);
            }
        }

        // Build keyframe
        const ts_copy = alloc.dupe(u8, ts) catch continue;
        const kf = buildKeyframeWorker(
            alloc,
            &positions,
            &anchors,
            &name_to_idx,
            &snapshot_map,
            &delta_map,
            &recency,
            if (prev_snap) |*ps| ps else null,
            queue.attractor_synsets,
            queue.attractor_labels,
            ts_copy,
            queue.x_scale,
        ) catch continue;

        // Collect new names added by this parse
        // We detect these by checking name_to_idx size vs original next_idx
        var nm_it = name_to_idx.iterator();
        while (nm_it.next()) |entry| {
            if (entry.value_ptr.* >= nds.next_idx) {
                // This is a name the worker added
                const synset_copy = alloc.dupe(u8, entry.key_ptr.*) catch continue;
                // Find the word from snapshot
                const word = if (snapshot_map.get(entry.key_ptr.*)) |se| se.word else entry.key_ptr.*;
                const word_copy = alloc.dupe(u8, word) catch continue;
                new_names.append(.{
                    .synset = synset_copy,
                    .word = word_copy,
                    .idx = entry.value_ptr.*,
                }) catch {};
            }
        }

        // Update prev_snap
        if (prev_snap) |*ps| ps.deinit();
        prev_snap = snapshot_map;

        // Build result
        const result = page.create(ReadyKeyframe) catch continue;
        result.* = .{
            .keyframe = kf,
            .timestamp = ts_copy,
            .new_names = new_names,
            .new_positions = new_positions,
            .delta_keys = delta_keys,
            .arena = arena,
        };

        // Push to queue (brief lock)
        {
            queue.mutex.lock();
            defer queue.mutex.unlock();
            queue.ready = result;
        }

        // Mark as known
        known.put(ts_copy, {}) catch {};

        std.debug.print("Live: prepared {s} ({d} points)\n", .{ ts, kf.points.len });
    }
}

const TsBuf = struct { ts: [20]u8, len: u8 };

fn findNewTimestamp(known: *std.StringHashMap(void)) ?TsBuf {
    var dir = std.fs.cwd().openDir("../snapshots", .{ .iterate = true }) catch return null;
    defer dir.close();

    var best: ?TsBuf = null;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (name.len >= 5 and std.mem.eql(u8, name[0..5], "snap_") and std.mem.endsWith(u8, name, ".json")) {
            const ts = name[5 .. name.len - 5];
            if (ts.len > 20) continue;
            if (!known.contains(ts)) {
                if (best == null or std.mem.order(u8, ts, best.?.ts[0..best.?.len]) == .lt) {
                    var buf: [20]u8 = undefined;
                    @memcpy(buf[0..ts.len], ts);
                    best = .{ .ts = buf, .len = @intCast(ts.len) };
                }
            }
        }
    }
    return best;
}

fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(alloc, 50 * 1024 * 1024);
}

fn parseAndMergePositions(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    positions: *std.StringHashMap([2]f32),
    new_positions: *std.ArrayList(PosEntry),
) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (positions.contains(name)) continue;
        const arr = entry.value_ptr.array.items;
        const x: f32 = switch (arr[0]) {
            .float => @floatCast(arr[0].float),
            .integer => @floatFromInt(arr[0].integer),
            else => 0.0,
        };
        const y: f32 = switch (arr[1]) {
            .float => @floatCast(arr[1].float),
            .integer => @floatFromInt(arr[1].integer),
            else => 0.0,
        };
        const name_copy = try alloc.dupe(u8, name);
        try positions.put(name_copy, .{ x, y });
        try new_positions.append(.{ .name = name_copy, .pos = .{ x, y } });
    }
}

fn parseSnapshot(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    anchors: *std.StringHashMap([constants.ANCHOR_DIM]f32),
    name_to_idx: *std.StringHashMap(u16),
    next_idx: *u16,
) !std.StringHashMap(data.SnapshotEntry) {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();

    var result = std.StringHashMap(data.SnapshotEntry).init(alloc);
    const obj = parsed.value.object;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const val = entry.value_ptr.object;

        const word_val = val.get("word") orelse continue;
        const word = switch (word_val) {
            .string => |s| s,
            else => continue,
        };
        const uc_val = val.get("update_count") orelse continue;
        const uc: i64 = switch (uc_val) {
            .integer => uc_val.integer,
            else => 0,
        };
        const ec_val = val.get("exemplar_count") orelse continue;
        const ec: i64 = switch (ec_val) {
            .integer => ec_val.integer,
            else => 0,
        };
        const unc_val = val.get("uncertainty") orelse continue;
        const unc: f64 = switch (unc_val) {
            .float => unc_val.float,
            .integer => @floatFromInt(unc_val.integer),
            else => 0.0,
        };

        if (val.get("anchor")) |anc_val| {
            if (anc_val == .array) {
                const items = anc_val.array.items;
                var anchor_f32: [constants.ANCHOR_DIM]f32 = undefined;
                for (0..@min(constants.ANCHOR_DIM, items.len)) |i| {
                    anchor_f32[i] = switch (items[i]) {
                        .float => @floatCast(items[i].float),
                        .integer => @floatFromInt(items[i].integer),
                        else => 0.0,
                    };
                }
                if (!anchors.contains(name)) {
                    const akey = try alloc.dupe(u8, name);
                    try anchors.put(akey, anchor_f32);
                }
            }
        }

        const name_copy = try alloc.dupe(u8, name);
        const word_copy = try alloc.dupe(u8, word);

        // Register name index (worker's own table)
        if (!name_to_idx.contains(name_copy)) {
            try name_to_idx.put(name_copy, next_idx.*);
            next_idx.* += 1;
        }

        try result.put(name_copy, .{
            .word = word_copy,
            .update_count = uc,
            .exemplar_count = ec,
            .uncertainty = unc,
            .anchor = undefined,
        });
    }
    return result;
}

fn parseDelta(alloc: std.mem.Allocator, bytes: []const u8) !std.StringHashMap(i64) {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    var result = std.StringHashMap(i64).init(alloc);
    const obj = parsed.value.object;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const name_copy = try alloc.dupe(u8, entry.key_ptr.*);
        const v: i64 = switch (entry.value_ptr.*) {
            .integer => entry.value_ptr.integer,
            else => 0,
        };
        try result.put(name_copy, v);
    }
    return result;
}

fn buildKeyframeWorker(
    alloc: std.mem.Allocator,
    positions: *const std.StringHashMap([2]f32),
    anchors: *const std.StringHashMap([constants.ANCHOR_DIM]f32),
    name_to_idx: *const std.StringHashMap(u16),
    snapshot: *std.StringHashMap(data.SnapshotEntry),
    delta: *std.StringHashMap(i64),
    recency: *std.StringHashMap(u32),
    prev_snapshot: ?*std.StringHashMap(data.SnapshotEntry),
    attractor_synsets: []const []const u8,
    attractor_labels: []const u8,
    timestamp: []const u8,
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

        const age: u32 = recency.get(name) orelse @as(u32, @intFromFloat(constants.FADE_WINDOW)) + 1;
        if (@as(f32, @floatFromInt(age)) > constants.FADE_WINDOW) continue;

        const fade = 1.0 - (@as(f32, @floatFromInt(age)) / constants.FADE_WINDOW);
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

    return .{
        .timestamp = timestamp,
        .points = try points.toOwnedSlice(),
        .max_delta = max_delta,
        .max_total = max_total,
        .num_hot = num_hot,
        .num_visible = @intCast(points.items.len),
    };
}
