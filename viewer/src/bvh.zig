const std = @import("std");
const data = @import("data.zig");

pub const MAX_POINTS: usize = 4096;
pub const MAX_NODES: usize = 2048;
const LEAF_SIZE: usize = 8;
const STACK_DEPTH: usize = 12;

pub const AABB = struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,

    pub fn intersects(self: AABB, other: AABB) bool {
        return self.min_x <= other.max_x and self.max_x >= other.min_x and
            self.min_y <= other.max_y and self.max_y >= other.min_y;
    }

    pub fn intersectsCircle(self: AABB, cx: f32, cy: f32, r: f32) bool {
        // Closest point on AABB to circle center
        const closest_x = std.math.clamp(cx, self.min_x, self.max_x);
        const closest_y = std.math.clamp(cy, self.min_y, self.max_y);
        const dx = cx - closest_x;
        const dy = cy - closest_y;
        return dx * dx + dy * dy <= r * r;
    }

    pub fn containsPoint(self: AABB, x: f32, y: f32) bool {
        return x >= self.min_x and x <= self.max_x and y >= self.min_y and y <= self.max_y;
    }

    pub fn merge(a: AABB, b: AABB) AABB {
        return .{
            .min_x = @min(a.min_x, b.min_x),
            .min_y = @min(a.min_y, b.min_y),
            .max_x = @max(a.max_x, b.max_x),
            .max_y = @max(a.max_y, b.max_y),
        };
    }

    pub fn empty() AABB {
        return .{
            .min_x = std.math.floatMax(f32),
            .min_y = std.math.floatMax(f32),
            .max_x = -std.math.floatMax(f32),
            .max_y = -std.math.floatMax(f32),
        };
    }

    pub fn expandToInclude(self: *AABB, x: f32, y: f32) void {
        self.min_x = @min(self.min_x, x);
        self.min_y = @min(self.min_y, y);
        self.max_x = @max(self.max_x, x);
        self.max_y = @max(self.max_y, y);
    }
};

const Node = struct {
    bbox: AABB,
    start: u16, // index into permuted index array
    count: u16, // number of points (>0 means leaf)
    left: u16, // left child node index
    right: u16, // right child node index
};

pub const QueryIter = struct {
    bvh: *const Bvh,
    query: AABB,
    stack: [STACK_DEPTH]u16,
    stack_top: u8,
    // Current leaf iteration state
    leaf_pos: u16,
    leaf_end: u16,

    pub fn next(self: *QueryIter) ?u16 {
        while (true) {
            // Drain current leaf
            if (self.leaf_pos < self.leaf_end) {
                const idx = self.bvh.indices[self.leaf_pos];
                self.leaf_pos += 1;
                return idx;
            }

            // Pop next node from stack
            if (self.stack_top == 0) return null;
            self.stack_top -= 1;
            const node_idx = self.stack[self.stack_top];
            const node = self.bvh.nodes[node_idx];

            if (!node.bbox.intersects(self.query)) continue;

            if (node.count > 0) {
                // Leaf node — set up iteration
                self.leaf_pos = node.start;
                self.leaf_end = node.start + node.count;
            } else {
                // Internal node — push children
                if (self.stack_top < STACK_DEPTH) {
                    self.stack[self.stack_top] = node.right;
                    self.stack_top += 1;
                }
                if (self.stack_top < STACK_DEPTH) {
                    self.stack[self.stack_top] = node.left;
                    self.stack_top += 1;
                }
            }
        }
    }
};

pub const RadiusIter = struct {
    inner: QueryIter,
    cx: f32,
    cy: f32,
    r2: f32,
    xs: []const f32,
    ys: []const f32,

    pub fn next(self: *RadiusIter) ?u16 {
        while (self.inner.next()) |idx| {
            const dx = self.xs[idx] - self.cx;
            const dy = self.ys[idx] - self.cy;
            if (dx * dx + dy * dy <= self.r2) return idx;
        }
        return null;
    }
};

pub const Bvh = struct {
    nodes: [MAX_NODES]Node,
    indices: [MAX_POINTS]u16,
    node_count: u16,
    point_count: u16,

    pub fn build(self: *Bvh, xs: []const f32, ys: []const f32, count: usize) void {
        const n: u16 = @intCast(@min(count, MAX_POINTS));
        self.point_count = n;
        self.node_count = 0;

        if (n == 0) return;

        // Initialize index array
        for (0..n) |i| {
            self.indices[i] = @intCast(i);
        }

        _ = self.buildRecursive(xs, ys, 0, n, 0);
    }

    fn buildRecursive(self: *Bvh, xs: []const f32, ys: []const f32, start: u16, end: u16, depth: u8) u16 {
        const node_idx = self.node_count;
        if (self.node_count >= MAX_NODES - 2) {
            // Out of nodes — make a leaf with remaining points
            self.nodes[node_idx] = .{
                .bbox = computeAABB(xs, ys, self.indices[start..end]),
                .start = start,
                .count = end - start,
                .left = 0,
                .right = 0,
            };
            self.node_count += 1;
            return node_idx;
        }
        self.node_count += 1;

        const count = end - start;

        if (count <= LEAF_SIZE) {
            self.nodes[node_idx] = .{
                .bbox = computeAABB(xs, ys, self.indices[start..end]),
                .start = start,
                .count = count,
                .left = 0,
                .right = 0,
            };
            return node_idx;
        }

        // Median split on alternating axis
        const split_x = (depth % 2 == 0);
        const indices_slice = self.indices[start..end];

        if (split_x) {
            std.mem.sort(u16, indices_slice, xs, struct {
                fn cmp(context: []const f32, a: u16, b: u16) bool {
                    return context[a] < context[b];
                }
            }.cmp);
        } else {
            std.mem.sort(u16, indices_slice, ys, struct {
                fn cmp(context: []const f32, a: u16, b: u16) bool {
                    return context[a] < context[b];
                }
            }.cmp);
        }

        const mid = start + count / 2;
        const left = self.buildRecursive(xs, ys, start, mid, depth + 1);
        const right = self.buildRecursive(xs, ys, mid, end, depth + 1);

        self.nodes[node_idx] = .{
            .bbox = AABB.merge(self.nodes[left].bbox, self.nodes[right].bbox),
            .start = start,
            .count = 0, // internal node
            .left = left,
            .right = right,
        };

        return node_idx;
    }

    pub fn queryAABB(self: *const Bvh, min_x: f32, min_y: f32, max_x: f32, max_y: f32) QueryIter {
        var iter = QueryIter{
            .bvh = self,
            .query = .{ .min_x = min_x, .min_y = min_y, .max_x = max_x, .max_y = max_y },
            .stack = undefined,
            .stack_top = 0,
            .leaf_pos = 0,
            .leaf_end = 0,
        };
        if (self.node_count > 0) {
            iter.stack[0] = 0; // root
            iter.stack_top = 1;
        }
        return iter;
    }

    pub fn queryRadius(self: *const Bvh, cx: f32, cy: f32, r: f32, xs: []const f32, ys: []const f32) RadiusIter {
        return .{
            .inner = self.queryAABB(cx - r, cy - r, cx + r, cy + r),
            .cx = cx,
            .cy = cy,
            .r2 = r * r,
            .xs = xs,
            .ys = ys,
        };
    }

    pub fn nearest(self: *const Bvh, wx: f32, wy: f32, max_dist: f32, xs: []const f32, ys: []const f32) ?u16 {
        var iter = self.queryAABB(wx - max_dist, wy - max_dist, wx + max_dist, wy + max_dist);
        var best_d2: f32 = max_dist * max_dist;
        var best_idx: ?u16 = null;

        while (iter.next()) |idx| {
            const dx = xs[idx] - wx;
            const dy = ys[idx] - wy;
            const d2 = dx * dx + dy * dy;
            if (d2 < best_d2) {
                best_d2 = d2;
                best_idx = idx;
            }
        }
        return best_idx;
    }
};

pub const FrameBvh = struct {
    xs: [MAX_POINTS]f32,
    ys: [MAX_POINTS]f32,
    bvh: Bvh,
    count: u16,

    pub fn buildFromPoints(self: *FrameBvh, points: []const data.Point) void {
        const n: u16 = @intCast(@min(points.len, MAX_POINTS));
        self.count = n;
        for (0..n) |i| {
            self.xs[i] = points[i].x;
            self.ys[i] = points[i].y;
        }
        self.bvh.build(self.xs[0..n], self.ys[0..n], n);
    }

    pub fn nearest(self: *const FrameBvh, wx: f32, wy: f32, max_dist: f32) ?u16 {
        return self.bvh.nearest(wx, wy, max_dist, self.xs[0..self.count], self.ys[0..self.count]);
    }
};

fn computeAABB(xs: []const f32, ys: []const f32, indices: []const u16) AABB {
    var box = AABB.empty();
    for (indices) |idx| {
        box.expandToInclude(xs[idx], ys[idx]);
    }
    return box;
}
