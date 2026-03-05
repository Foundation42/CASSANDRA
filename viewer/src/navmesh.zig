const std = @import("std");
const constants = @import("constants.zig");
const data = @import("data.zig");

pub const K: usize = 6;
pub const MAX_NODES: usize = 8192;
pub const MAX_ATTRACTOR_PAIRS: usize = (constants.NUM_ATTRACTORS * (constants.NUM_ATTRACTORS - 1)) / 2;
pub const MAX_PATH_LEN: usize = 16;

/// One edge in the kNN graph.
pub const Edge = struct {
    to: u16,
    dist: f32,
};

/// A single attractor-to-attractor path.
pub const NavPath = struct {
    nodes: [MAX_PATH_LEN]u16 = undefined,
    len: u8 = 0,
    cluster_a: u8 = 0,
    cluster_b: u8 = 0,
};

/// Build the kNN graph from anchor embeddings.
/// Returns BIDIRECTIONAL adjacency: for every A→B kNN edge, also stores B→A.
/// Each node can have up to MAX_ADJ neighbors after symmetrization.
pub const MAX_ADJ: usize = K * 4; // generous bound for bidirectional edges

pub fn buildGraph(
    name_indices: []const u16,
    anchors: [][constants.ANCHOR_DIM]f32,
    alloc: std.mem.Allocator,
) !struct { adj: [][MAX_ADJ]u16, adj_len: []u8, local_to_name: []u16, name_to_local: []u16 } {
    const n = name_indices.len;
    std.debug.assert(n == anchors.len);
    std.debug.assert(n <= MAX_NODES);

    // First build directed kNN
    const knn = try alloc.alloc([K]u16, n);

    for (0..n) |i| {
        var best_dist: [K]f32 = .{std.math.inf(f32)} ** K;
        var best_idx: [K]u16 = .{0} ** K;
        var worst_k: usize = 0;

        for (0..n) |j| {
            if (i == j) continue;
            const sim = data.cosineSimilarity(anchors[i], anchors[j]);
            const dist = 1.0 - sim;

            if (dist < best_dist[worst_k]) {
                best_dist[worst_k] = dist;
                best_idx[worst_k] = @intCast(j);
                // Find new worst
                worst_k = 0;
                for (1..K) |ki| {
                    if (best_dist[ki] > best_dist[worst_k]) {
                        worst_k = ki;
                    }
                }
            }
        }
        knn[i] = best_idx;
    }

    // Symmetrize: build bidirectional adjacency lists
    const adj = try alloc.alloc([MAX_ADJ]u16, n);
    const adj_len = try alloc.alloc(u8, n);
    @memset(adj_len, 0);

    for (0..n) |i| {
        for (knn[i]) |j| {
            // Add i→j
            addEdge(adj, adj_len, @intCast(i), j);
            // Add j→i (reverse)
            addEdge(adj, adj_len, j, @intCast(i));
        }
    }

    // Build name mappings
    var max_name: u16 = 0;
    for (name_indices) |ni| {
        if (ni > max_name) max_name = ni;
    }
    const map_size = @as(usize, max_name) + 1;
    const name_to_local = try alloc.alloc(u16, map_size);
    @memset(name_to_local, 0xFFFF);

    const local_to_name = try alloc.alloc(u16, n);
    @memcpy(local_to_name, name_indices);

    for (name_indices, 0..) |ni, i| {
        name_to_local[ni] = @intCast(i);
    }

    std.debug.print("Worker: built kNN graph ({d} nodes, symmetrized)\n", .{n});

    return .{
        .adj = adj,
        .adj_len = adj_len,
        .local_to_name = local_to_name,
        .name_to_local = name_to_local,
    };
}

fn addEdge(adj: [][MAX_ADJ]u16, adj_len: []u8, from: u16, to: u16) void {
    const len = adj_len[from];
    if (len >= MAX_ADJ) return;
    // Check duplicate
    for (adj[from][0..len]) |existing| {
        if (existing == to) return;
    }
    adj[from][len] = to;
    adj_len[from] = len + 1;
}

/// BFS from each attractor to find shortest-hop paths to all other attractors.
pub fn computePaths(
    adj: []const [MAX_ADJ]u16,
    adj_len: []const u8,
    local_to_name: []const u16,
    name_to_local: []const u16,
    attractor_name_indices: []const u16,
    clusters: []const u8,
    alloc: std.mem.Allocator,
) !struct { paths: [MAX_ATTRACTOR_PAIRS]NavPath, num_paths: usize } {
    const n = adj.len;
    var result: [MAX_ATTRACTOR_PAIRS]NavPath = undefined;
    var num_paths: usize = 0;

    // Map attractor name_idx to local index
    var att_local: [constants.NUM_ATTRACTORS]u16 = undefined;
    const num_att = attractor_name_indices.len;
    for (attractor_name_indices, 0..) |ni, i| {
        if (ni < name_to_local.len) {
            att_local[i] = name_to_local[ni];
        } else {
            att_local[i] = 0xFFFF;
        }
    }

    // BFS workspace
    const prev_buf = try alloc.alloc(u16, n);
    defer alloc.free(prev_buf);
    const queue_buf = try alloc.alloc(u16, n);
    defer alloc.free(queue_buf);

    // Run BFS from each attractor
    for (0..num_att) |ai| {
        const src = att_local[ai];
        if (src == 0xFFFF) continue;

        // Reset
        @memset(prev_buf, 0xFFFF);
        prev_buf[src] = src; // mark visited (self = root)

        // BFS queue
        queue_buf[0] = src;
        var head: usize = 0;
        var tail: usize = 1;

        // Count targets
        var targets_remaining: usize = 0;
        for (0..num_att) |bi| {
            if (bi > ai and att_local[bi] != 0xFFFF) targets_remaining += 1;
        }

        while (head < tail and targets_remaining > 0) {
            const u = queue_buf[head];
            head += 1;

            // Check if u is a target
            for (0..num_att) |bi| {
                if (bi > ai and att_local[bi] == u) {
                    targets_remaining -= 1;
                    break;
                }
            }

            // Expand neighbors
            const degree = adj_len[u];
            for (adj[u][0..degree]) |v| {
                if (prev_buf[v] == 0xFFFF) { // not visited
                    prev_buf[v] = u;
                    queue_buf[tail] = v;
                    tail += 1;
                }
            }
        }

        // Extract paths from ai to each bi > ai
        for (ai + 1..num_att) |bi| {
            const dst = att_local[bi];
            if (dst == 0xFFFF) continue;
            if (prev_buf[dst] == 0xFFFF) continue; // unreachable

            // Trace back
            var path_buf: [MAX_PATH_LEN]u16 = undefined;
            var path_len: u8 = 0;
            var cur: u16 = dst;
            while (path_len < MAX_PATH_LEN) {
                path_buf[path_len] = local_to_name[cur];
                path_len += 1;
                if (cur == src) break;
                cur = prev_buf[cur];
            }

            if (path_len > 1 and num_paths < MAX_ATTRACTOR_PAIRS) {
                // Reverse so path goes src -> dst
                var nav = NavPath{
                    .len = path_len,
                    .cluster_a = if (ai < clusters.len) clusters[ai] else 0,
                    .cluster_b = if (bi < clusters.len) clusters[bi] else 0,
                };
                for (0..path_len) |pi| {
                    nav.nodes[pi] = path_buf[path_len - 1 - pi];
                }
                result[num_paths] = nav;
                num_paths += 1;
            }
        }
    }

    return .{ .paths = result, .num_paths = num_paths };
}
