const std = @import("std");
const constants = @import("constants.zig");

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

pub const SnapshotEntry = struct {
    word: []const u8,
    update_count: i64,
    exemplar_count: i64,
    uncertainty: f64,
    anchor: []f64,
};

// --- Clustering ---

pub fn cosineSimilarity(a: [constants.ANCHOR_DIM]f32, b: [constants.ANCHOR_DIM]f32) f32 {
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

