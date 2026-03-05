const std = @import("std");
const constants = @import("constants.zig");
const timeline_mod = @import("timeline.zig");

pub const Point = struct {
    name_idx: u16,
    x: f32,
    y: f32,
    total: f32,
    exemplars: f32,
    delta: f32,
    uncertainty: f32,
    u_shift: f32,
    fade: f32,
    cluster: u8,
    is_attractor: bool,
    nearest_attractor: u16,
    speed: f32 = 0, // physics velocity magnitude (set by physics.applyToPoints)
};

pub const Keyframe = struct {
    timestamp: []const u8,
    points: []Point,
    max_delta: f32,
    max_total: f32,
    num_hot: u32,
    num_visible: u32,
    wall_time: i64 = 0,
};

pub const NucleusData = struct {
    allocator: std.mem.Allocator,
    // Name table: index → synset name, index → display word
    synset_names: std.ArrayList([]const u8),
    display_words: std.ArrayList([]const u8),
    name_to_idx: std.StringHashMap(u16),
    // Positions (static)
    positions: std.StringHashMap([2]f32),
    // Anchor embeddings from snapshot (for clustering)
    anchors: std.StringHashMap([constants.ANCHOR_DIM]f32),
    // Keyframes
    keyframes: std.ArrayList(Keyframe),
    // Cluster assignments (attractor name → cluster id)
    attractor_names: [constants.NUM_ATTRACTORS]u16,
    num_attractors: usize,

    // All string storage
    string_arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) NucleusData {
        return .{
            .allocator = allocator,
            .synset_names = std.ArrayList([]const u8).init(allocator),
            .display_words = std.ArrayList([]const u8).init(allocator),
            .name_to_idx = std.StringHashMap(u16).init(allocator),
            .positions = std.StringHashMap([2]f32).init(allocator),
            .anchors = std.StringHashMap([constants.ANCHOR_DIM]f32).init(allocator),
            .keyframes = std.ArrayList(Keyframe).init(allocator),
            .attractor_names = undefined,
            .num_attractors = 0,
            .string_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        };
    }

    pub fn getOrAddName(self: *NucleusData, synset_name: []const u8, display_word: []const u8) !u16 {
        if (self.name_to_idx.get(synset_name)) |idx| {
            return idx;
        }
        const idx: u16 = @intCast(self.synset_names.items.len);
        const arena = self.string_arena.allocator();
        const name_copy = try arena.dupe(u8, synset_name);
        const word_copy = try arena.dupe(u8, display_word);
        try self.synset_names.append(name_copy);
        try self.display_words.append(word_copy);
        try self.name_to_idx.put(name_copy, idx);
        return idx;
    }

    pub fn displayWord(self: *const NucleusData, idx: u16) []const u8 {
        return self.display_words.items[idx];
    }

    pub fn synsetName(self: *const NucleusData, idx: u16) []const u8 {
        return self.synset_names.items[idx];
    }
};

// --- JSON Loading ---

pub fn loadPositions(data: *NucleusData, path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(data.allocator, 50 * 1024 * 1024);
    defer data.allocator.free(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, data.allocator, content, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        // Skip keys already loaded (idempotent reload)
        if (data.positions.contains(name)) continue;
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
        const arena = data.string_arena.allocator();
        const name_copy = try arena.dupe(u8, name);
        try data.positions.put(name_copy, .{ x, y });
    }
}

pub const SnapshotEntry = struct {
    word: []const u8,
    update_count: i64,
    exemplar_count: i64,
    uncertainty: f64,
    anchor: []f64,
};

pub fn loadSnapshot(data: *NucleusData, path: []const u8) !std.StringHashMap(SnapshotEntry) {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(data.allocator, 50 * 1024 * 1024);
    defer data.allocator.free(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, data.allocator, content, .{});
    defer parsed.deinit();

    var result = std.StringHashMap(SnapshotEntry).init(data.allocator);
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

        // Parse anchor
        var anchor_arr: [constants.ANCHOR_DIM]f64 = undefined;
        if (val.get("anchor")) |anc_val| {
            if (anc_val == .array) {
                const items = anc_val.array.items;
                for (0..@min(constants.ANCHOR_DIM, items.len)) |i| {
                    anchor_arr[i] = switch (items[i]) {
                        .float => items[i].float,
                        .integer => @floatFromInt(items[i].integer),
                        else => 0.0,
                    };
                }
                // Store anchor for clustering
                var anchor_f32: [constants.ANCHOR_DIM]f32 = undefined;
                for (0..constants.ANCHOR_DIM) |i| {
                    anchor_f32[i] = @floatCast(anchor_arr[i]);
                }
                const arena = data.string_arena.allocator();
                const key = try arena.dupe(u8, name);
                try data.anchors.put(key, anchor_f32);
            }
        }

        const arena = data.string_arena.allocator();
        const name_copy = try arena.dupe(u8, name);
        const word_copy = try arena.dupe(u8, word);
        _ = try data.getOrAddName(name_copy, word_copy);

        try result.put(name_copy, .{
            .word = word_copy,
            .update_count = uc,
            .exemplar_count = ec,
            .uncertainty = unc,
            .anchor = &anchor_arr,
        });
    }
    return result;
}

pub fn loadDelta(data: *NucleusData, path: []const u8) !std.StringHashMap(i64) {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(data.allocator, 50 * 1024 * 1024);
    defer data.allocator.free(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, data.allocator, content, .{});
    defer parsed.deinit();

    var result = std.StringHashMap(i64).init(data.allocator);
    const obj = parsed.value.object;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const arena = data.string_arena.allocator();
        const name_copy = try arena.dupe(u8, entry.key_ptr.*);
        const v: i64 = switch (entry.value_ptr.*) {
            .integer => entry.value_ptr.integer,
            else => 0,
        };
        try result.put(name_copy, v);
    }
    return result;
}

// --- Clustering ---

fn cosineSimilarity(a: [constants.ANCHOR_DIM]f32, b: [constants.ANCHOR_DIM]f32) f32 {
    var dot: f32 = 0;
    var na: f32 = 0;
    var nb: f32 = 0;
    for (0..constants.ANCHOR_DIM) |i| {
        dot += a[i] * b[i];
        na += a[i] * a[i];
        nb += b[i] * b[i];
    }
    const denom = @sqrt(na) * @sqrt(nb);
    if (denom < 1e-10) return 0;
    return dot / denom;
}

fn vecAdd(a: *[constants.ANCHOR_DIM]f32, b: [constants.ANCHOR_DIM]f32) void {
    for (0..constants.ANCHOR_DIM) |i| a[i] += b[i];
}

fn vecScale(a: *[constants.ANCHOR_DIM]f32, s: f32) void {
    for (0..constants.ANCHOR_DIM) |i| a[i] *= s;
}

fn vecZero(a: *[constants.ANCHOR_DIM]f32) void {
    for (0..constants.ANCHOR_DIM) |i| a[i] = 0;
}

// Simple k-means on attractor anchors
pub fn kmeansAttractors(
    attractor_synsets: []const []const u8,
    anchors: *const std.StringHashMap([constants.ANCHOR_DIM]f32),
    k: u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    const n = attractor_synsets.len;
    const labels = try allocator.alloc(u8, n);
    @memset(labels, 0);

    // Gather attractor embeddings
    const embeds = try allocator.alloc([constants.ANCHOR_DIM]f32, n);
    defer allocator.free(embeds);
    for (attractor_synsets, 0..) |name, i| {
        if (anchors.get(name)) |a| {
            embeds[i] = a;
        } else {
            @memset(&embeds[i], 0);
        }
    }

    // Init centroids = first k attractors
    const centroids = try allocator.alloc([constants.ANCHOR_DIM]f32, k);
    defer allocator.free(centroids);
    for (0..k) |i| {
        if (i < n) {
            centroids[i] = embeds[i];
        } else {
            @memset(&centroids[i], 0);
        }
    }

    // Run 20 iterations
    const counts = try allocator.alloc(u32, k);
    defer allocator.free(counts);
    for (0..20) |_| {
        // Assign
        for (0..n) |i| {
            var best_sim: f32 = -2;
            var best_k: u8 = 0;
            for (0..k) |ki| {
                const sim = cosineSimilarity(embeds[i], centroids[ki]);
                if (sim > best_sim) {
                    best_sim = sim;
                    best_k = @intCast(ki);
                }
            }
            labels[i] = best_k;
        }
        // Update centroids
        for (0..k) |ki| {
            vecZero(&centroids[ki]);
            counts[ki] = 0;
        }
        for (0..n) |i| {
            vecAdd(&centroids[labels[i]], embeds[i]);
            counts[labels[i]] += 1;
        }
        for (0..k) |ki| {
            if (counts[ki] > 0) {
                vecScale(&centroids[ki], 1.0 / @as(f32, @floatFromInt(counts[ki])));
            }
        }
    }

    return labels;
}

// Assign all nuclei to cluster of nearest attractor
pub fn assignAllClusters(
    name: []const u8,
    attractor_synsets: []const []const u8,
    attractor_labels: []const u8,
    anchors: *const std.StringHashMap([constants.ANCHOR_DIM]f32),
) struct { cluster: u8, nearest: u16 } {
    const my_anchor = anchors.get(name) orelse {
        return .{ .cluster = 0, .nearest = 0 };
    };
    var best_sim: f32 = -2;
    var best_idx: u16 = 0;
    for (attractor_synsets, 0..) |att_name, i| {
        if (anchors.get(att_name)) |att_anchor| {
            const sim = cosineSimilarity(my_anchor, att_anchor);
            if (sim > best_sim) {
                best_sim = sim;
                best_idx = @intCast(i);
            }
        }
    }
    const cluster = if (best_idx < attractor_labels.len) attractor_labels[best_idx] else 0;
    return .{ .cluster = cluster, .nearest = best_idx };
}

// --- Build keyframes ---

pub const TimestampInfo = struct {
    timestamp: []const u8,
    snap_path: []const u8,
    delta_path: []const u8,
};

pub fn scanSnapshots(allocator: std.mem.Allocator, dir_path: []const u8) ![]TimestampInfo {
    var list = std.ArrayList(TimestampInfo).init(allocator);
    const arena_alloc = allocator;

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (name.len >= 5 and std.mem.eql(u8, name[0..5], "snap_") and std.mem.endsWith(u8, name, ".json")) {
            // Extract timestamp: snap_YYYYMMDD_HHMMSS.json
            const ts = name[5 .. name.len - 5]; // strip "snap_" and ".json"
            const ts_copy = try arena_alloc.dupe(u8, ts);
            const snap_name = try arena_alloc.dupe(u8, name);
            const delta_name = try std.fmt.allocPrint(arena_alloc, "delta_{s}.json", .{ts});

            const snap_path = try std.fmt.allocPrint(arena_alloc, "{s}/{s}", .{ dir_path, snap_name });
            const delta_path = try std.fmt.allocPrint(arena_alloc, "{s}/{s}", .{ dir_path, delta_name });

            try list.append(.{
                .timestamp = ts_copy,
                .snap_path = snap_path,
                .delta_path = delta_path,
            });
        }
    }

    // Sort by timestamp
    const items = try list.toOwnedSlice();
    std.mem.sort(TimestampInfo, items, {}, struct {
        fn lessThan(_: void, a: TimestampInfo, b: TimestampInfo) bool {
            return std.mem.order(u8, a.timestamp, b.timestamp) == .lt;
        }
    }.lessThan);
    return items;
}

pub fn buildKeyframe(
    nd: *NucleusData,
    snapshot: *std.StringHashMap(SnapshotEntry),
    delta: *std.StringHashMap(i64),
    recency: *std.StringHashMap(u32),
    prev_snapshot: ?*std.StringHashMap(SnapshotEntry),
    attractor_synsets: []const []const u8,
    attractor_labels: []const u8,
    timestamp: []const u8,
    x_scale: f32,
) !Keyframe {
    var points = std.ArrayList(Point).init(nd.allocator);
    var max_delta: f32 = 1;
    var max_total: f32 = 1;
    var num_hot: u32 = 0;

    var pos_it = nd.positions.iterator();
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

        // Cluster assignment
        const cluster_info = assignAllClusters(name, attractor_synsets, attractor_labels, &nd.anchors);

        // Is this an attractor?
        var is_att = false;
        for (attractor_synsets) |aname| {
            if (std.mem.eql(u8, name, aname)) {
                is_att = true;
                break;
            }
        }

        const name_idx = nd.name_to_idx.get(name) orelse blk: {
            const idx = try nd.getOrAddName(name, snap_entry.word);
            break :blk idx;
        };

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
        .wall_time = timeline_mod.parseTimestamp(timestamp),
    };
}

// Find top N attractors by update_count from a snapshot
pub fn findAttractors(snapshot: *std.StringHashMap(SnapshotEntry), allocator: std.mem.Allocator) ![][]const u8 {
    const Entry = struct {
        name: []const u8,
        count: i64,
    };
    var entries = std.ArrayList(Entry).init(allocator);
    defer entries.deinit();

    var it = snapshot.iterator();
    while (it.next()) |e| {
        try entries.append(.{ .name = e.key_ptr.*, .count = e.value_ptr.update_count });
    }

    const items = entries.items;
    std.mem.sort(Entry, items, {}, struct {
        fn cmp(_: void, a: Entry, b: Entry) bool {
            return a.count > b.count;
        }
    }.cmp);

    const n = @min(constants.NUM_ATTRACTORS, items.len);
    const result = try allocator.alloc([]const u8, n);
    for (0..n) |i| {
        result[i] = items[i].name;
    }
    return result;
}

// Reconstruct recency by replaying deltas
pub fn reconstructRecency(
    timestamps: []const TimestampInfo,
    nd: *NucleusData,
) ![]std.StringHashMap(u32) {
    const recencies = try nd.allocator.alloc(std.StringHashMap(u32), timestamps.len);

    // Track running recency
    var running = std.StringHashMap(u32).init(nd.allocator);

    for (timestamps, 0..) |ts_info, ti| {
        // Load this delta
        var delta = loadDelta(nd, ts_info.delta_path) catch std.StringHashMap(i64).init(nd.allocator);

        // Age all existing entries
        var age_it = running.iterator();
        while (age_it.next()) |entry| {
            entry.value_ptr.* += 1;
        }

        // Reset active ones to 0
        var delta_it = delta.iterator();
        while (delta_it.next()) |d_entry| {
            const arena = nd.string_arena.allocator();
            const key = arena.dupe(u8, d_entry.key_ptr.*) catch continue;
            running.put(key, 0) catch {};
        }

        // Remove old entries
        var remove_list = std.ArrayList([]const u8).init(nd.allocator);
        defer remove_list.deinit();
        var rm_it = running.iterator();
        while (rm_it.next()) |entry| {
            if (entry.value_ptr.* > @as(u32, @intFromFloat(constants.FADE_WINDOW)) * 2) {
                remove_list.append(entry.key_ptr.*) catch {};
            }
        }
        for (remove_list.items) |key| {
            _ = running.remove(key);
        }

        // Clone for this timestamp
        recencies[ti] = std.StringHashMap(u32).init(nd.allocator);
        var clone_it = running.iterator();
        while (clone_it.next()) |entry| {
            recencies[ti].put(entry.key_ptr.*, entry.value_ptr.*) catch {};
        }

        delta.deinit();
    }

    return recencies;
}
