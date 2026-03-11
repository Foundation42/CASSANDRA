const std = @import("std");
const constants = @import("constants.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

/// Thin wrapper around a sqlite3 prepared statement.
pub const Statement = struct {
    stmt: *c.sqlite3_stmt,

    pub fn step(self: *const Statement) bool {
        return c.sqlite3_step(self.stmt) == c.SQLITE_ROW;
    }

    pub fn columnInt(self: *const Statement, col: c_int) i64 {
        return c.sqlite3_column_int64(self.stmt, col);
    }

    pub fn columnDouble(self: *const Statement, col: c_int) f64 {
        return c.sqlite3_column_double(self.stmt, col);
    }

    pub fn columnText(self: *const Statement, col: c_int) ?[]const u8 {
        const ptr = c.sqlite3_column_text(self.stmt, col);
        if (ptr == null) return null;
        const len: usize = @intCast(c.sqlite3_column_bytes(self.stmt, col));
        return ptr[0..len];
    }

    pub fn columnBlob(self: *const Statement, col: c_int) ?[]const u8 {
        const ptr: ?[*]const u8 = @ptrCast(c.sqlite3_column_blob(self.stmt, col));
        if (ptr == null) return null;
        const len: usize = @intCast(c.sqlite3_column_bytes(self.stmt, col));
        return ptr.?[0..len];
    }

    pub fn reset(self: *const Statement) void {
        _ = c.sqlite3_reset(self.stmt);
    }

    pub fn bindInt(self: *const Statement, col: c_int, val: i64) void {
        _ = c.sqlite3_bind_int64(self.stmt, col, val);
    }

    pub fn finalize(self: *Statement) void {
        _ = c.sqlite3_finalize(self.stmt);
    }
};

pub const NucleusRow = struct {
    synset: []const u8,
    word: []const u8,
    anchor: [constants.ANCHOR_DIM]f32,
};

pub const PositionRow = struct {
    synset: []const u8,
    x: f32,
    y: f32,
};

pub const SnapshotRow = struct {
    id: i64,
    timestamp: []const u8,
    wall_time: i64,
};

pub const ObservationRow = struct {
    synset: []const u8,
    update_count: i64,
    exemplar_count: i64,
    uncertainty: f64,
    delta: i64,
};

/// Database handle wrapping sqlite3.
pub const Db = struct {
    handle: *c.sqlite3,

    // Pre-compiled statements
    stmt_snapshots_after: Statement,
    stmt_snapshots_after_time: Statement,
    stmt_observations: Statement,
    stmt_all_positions: Statement,

    pub fn open(path: [*:0]const u8) !Db {
        var handle: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_WAL;
        const rc = c.sqlite3_open_v2(path, &handle, flags, null);
        if (rc != c.SQLITE_OK or handle == null) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return error.SqliteOpenFailed;
        }
        const h = handle.?;

        // Prepare reusable statements
        const stmt_sa = try prepareStmt(h, "SELECT id, timestamp, wall_time FROM snapshots WHERE id > ? ORDER BY id");
        const stmt_sat = try prepareStmt(h, "SELECT id, timestamp, wall_time FROM snapshots WHERE wall_time > ? ORDER BY id");
        const stmt_obs = try prepareStmt(h, "SELECT synset, update_count, exemplar_count, uncertainty, delta FROM observations WHERE snapshot_id = ?");
        const stmt_pos = try prepareStmt(h, "SELECT synset, x, y FROM positions");

        return .{
            .handle = h,
            .stmt_snapshots_after = stmt_sa,
            .stmt_snapshots_after_time = stmt_sat,
            .stmt_observations = stmt_obs,
            .stmt_all_positions = stmt_pos,
        };
    }

    pub fn close(self: *Db) void {
        self.stmt_snapshots_after.finalize();
        self.stmt_snapshots_after_time.finalize();
        self.stmt_observations.finalize();
        self.stmt_all_positions.finalize();
        _ = c.sqlite3_close(self.handle);
    }

    /// Load all nuclei (synset, word, anchor). Called once at startup.
    pub fn getAllNuclei(self: *Db, alloc: std.mem.Allocator) !std.ArrayList(NucleusRow) {
        var stmt = try prepareStmt(self.handle, "SELECT synset, word, anchor FROM nuclei");
        defer stmt.finalize();

        var result = std.ArrayList(NucleusRow).init(alloc);
        while (stmt.step()) {
            const synset_raw = stmt.columnText(0) orelse continue;
            const word_raw = stmt.columnText(1) orelse continue;
            const blob = stmt.columnBlob(2) orelse continue;
            if (blob.len != constants.ANCHOR_DIM * 4) continue;

            const synset = try alloc.dupe(u8, synset_raw);
            const word = try alloc.dupe(u8, word_raw);

            // Unpack 50 × f32 little-endian
            var anchor: [constants.ANCHOR_DIM]f32 = undefined;
            const floats: *const [constants.ANCHOR_DIM]f32 = @ptrCast(@alignCast(blob.ptr));
            anchor = floats.*;

            try result.append(.{ .synset = synset, .word = word, .anchor = anchor });
        }
        return result;
    }

    /// Load all positions. Called once at startup.
    pub fn getAllPositions(self: *Db, alloc: std.mem.Allocator) !std.ArrayList(PositionRow) {
        self.stmt_all_positions.reset();
        var result = std.ArrayList(PositionRow).init(alloc);
        while (self.stmt_all_positions.step()) {
            const synset_raw = self.stmt_all_positions.columnText(0) orelse continue;
            const synset = try alloc.dupe(u8, synset_raw);
            const x: f32 = @floatCast(self.stmt_all_positions.columnDouble(1));
            const y: f32 = @floatCast(self.stmt_all_positions.columnDouble(2));
            try result.append(.{ .synset = synset, .x = x, .y = y });
        }
        return result;
    }

    /// List all snapshot IDs in order (for bootstrap).
    pub fn listSnapshotIds(self: *Db) !Statement {
        return try prepareStmt(self.handle, "SELECT id, timestamp, wall_time FROM snapshots ORDER BY id");
    }

    /// List snapshot IDs with wall_time after a cutoff (for time-windowed bootstrap).
    pub fn listSnapshotIdsAfterTime(self: *Db, min_wall_time: i64) *Statement {
        self.stmt_snapshots_after_time.reset();
        self.stmt_snapshots_after_time.bindInt(1, min_wall_time);
        return &self.stmt_snapshots_after_time;
    }

    /// Get snapshots with id > last_id (for live polling).
    pub fn getSnapshotsAfter(self: *Db, last_id: i64) *Statement {
        self.stmt_snapshots_after.reset();
        self.stmt_snapshots_after.bindInt(1, last_id);
        return &self.stmt_snapshots_after;
    }

    /// Get all observations for a given snapshot_id.
    pub fn getObservations(self: *Db, snapshot_id: i64) *Statement {
        self.stmt_observations.reset();
        self.stmt_observations.bindInt(1, snapshot_id);
        return &self.stmt_observations;
    }
};

fn prepareStmt(handle: *c.sqlite3, sql: [*:0]const u8) !Statement {
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(handle, sql, -1, &stmt, null);
    if (rc != c.SQLITE_OK or stmt == null) {
        return error.SqlitePrepareFailed;
    }
    return .{ .stmt = stmt.? };
}
