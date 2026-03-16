const std = @import("std");
const terminal_mod = @import("terminal.zig");

pub const c = @cImport({
    @cInclude("quickjs.h");
    @cInclude("quickjs-zig-helpers.h");
});

const MAX_OUTPUT: usize = 64 * 1024;
const MAX_JOBS: usize = 16;

const Job = struct {
    code: [32768]u8 = undefined,
    code_len: usize = 0,
    filename: [256]u8 = undefined,
    filename_len: usize = 0,
    is_file: bool = false,
};

/// Thread-safe JavaScript runtime with worker thread.
/// JS executes on the worker; terminal output is queued and drained by the main thread.
pub const JsRuntime = struct {
    // Worker thread
    worker: ?std.Thread = null,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Job queue: main → worker
    mutex: std.Thread.Mutex = .{},
    jobs: [MAX_JOBS]Job = undefined,
    job_count: usize = 0,

    // Output queue: worker → main (ANSI bytes for the terminal)
    output_buf: [MAX_OUTPUT]u8 = undefined,
    output_len: usize = 0,
    output_mutex: std.Thread.Mutex = .{},

    // Busy flag (worker is executing)
    busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Terminal ref (for reading dimensions — main thread only for actual writes)
    term: *terminal_mod.Terminal = undefined,

    pub fn init(self: *JsRuntime, term: *terminal_mod.Terminal) void {
        self.term = term;
        self.shutdown.store(false, .release);
        self.worker = std.Thread.spawn(.{}, workerLoop, .{self}) catch null;
    }

    pub fn deinit(self: *JsRuntime) void {
        self.shutdown.store(true, .release);
        if (self.worker) |w| {
            w.join();
            self.worker = null;
        }
    }

    /// Submit inline JS code for execution on the worker thread.
    pub fn eval(self: *JsRuntime, code: []const u8, filename: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.job_count >= MAX_JOBS) return;

        var job = &self.jobs[self.job_count];
        job.is_file = false;
        const cl = @min(code.len, job.code.len - 1);
        @memcpy(job.code[0..cl], code[0..cl]);
        job.code_len = cl;
        const fl = @min(filename.len, job.filename.len - 1);
        @memcpy(job.filename[0..fl], filename[0..fl]);
        job.filename_len = fl;
        self.job_count += 1;
    }

    /// Submit a JS file for execution on the worker thread.
    pub fn evalFile(self: *JsRuntime, path: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.job_count >= MAX_JOBS) return;

        var job = &self.jobs[self.job_count];
        job.is_file = true;
        const pl = @min(path.len, job.filename.len - 1);
        @memcpy(job.filename[0..pl], path[0..pl]);
        job.filename_len = pl;
        job.code_len = 0;
        self.job_count += 1;
    }

    /// Returns true if the worker is currently executing a script.
    pub fn isBusy(self: *JsRuntime) bool {
        return self.busy.load(.acquire);
    }

    /// Drain output buffer into the terminal. Call from main thread each frame.
    pub fn drainOutput(self: *JsRuntime) void {
        self.output_mutex.lock();
        const n = self.output_len;
        if (n == 0) {
            self.output_mutex.unlock();
            return;
        }
        // Copy to local buffer to minimize lock time
        var local: [MAX_OUTPUT]u8 = undefined;
        @memcpy(local[0..n], self.output_buf[0..n]);
        self.output_len = 0;
        self.output_mutex.unlock();

        self.term.write(local[0..n]);
    }

    /// Push output bytes from the worker thread (thread-safe).
    fn pushOutput(self: *JsRuntime, data: []const u8) void {
        self.output_mutex.lock();
        defer self.output_mutex.unlock();
        const avail = MAX_OUTPUT - self.output_len;
        const n = @min(data.len, avail);
        if (n > 0) {
            @memcpy(self.output_buf[self.output_len..][0..n], data[0..n]);
            self.output_len += n;
        }
    }

    /// Push formatted output from the worker thread.
    fn pushOutputFmt(self: *JsRuntime, comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        const result = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.pushOutput(result);
    }

    // ---------------------------------------------------------------
    // Worker thread
    // ---------------------------------------------------------------

    fn workerLoop(self: *JsRuntime) void {
        // Create QuickJS runtime on this thread (it owns it exclusively)
        const rt = c.JS_NewRuntime() orelse return;
        defer c.JS_FreeRuntime(rt);
        const ctx = c.JS_NewContext(rt) orelse return;
        defer c.JS_FreeContext(ctx);

        // Store self pointer for callbacks
        c.JS_SetContextOpaque(ctx, @ptrCast(self));

        // Register built-in functions
        registerBuiltins(ctx, self);

        while (!self.shutdown.load(.acquire)) {
            // Pop a job
            var job: ?Job = null;
            {
                self.mutex.lock();
                if (self.job_count > 0) {
                    job = self.jobs[0];
                    // Shift remaining jobs
                    if (self.job_count > 1) {
                        for (1..self.job_count) |i| {
                            self.jobs[i - 1] = self.jobs[i];
                        }
                    }
                    self.job_count -= 1;
                }
                self.mutex.unlock();
            }

            if (job) |j| {
                self.busy.store(true, .release);

                if (j.is_file) {
                    execFile(ctx, self, j.filename[0..j.filename_len]);
                } else {
                    execCode(ctx, self, j.code[0..j.code_len], j.filename[0..j.filename_len]);
                }

                self.busy.store(false, .release);
            } else {
                // No work — sleep briefly
                std.time.sleep(10 * std.time.ns_per_ms);
            }
        }
    }

    fn execCode(ctx: *c.JSContext, self: *JsRuntime, code: []const u8, filename: []const u8) void {
        var code_z: [32768]u8 = undefined;
        const cl = @min(code.len, code_z.len - 1);
        @memcpy(code_z[0..cl], code[0..cl]);
        code_z[cl] = 0;

        var file_z: [256]u8 = undefined;
        const fl = @min(filename.len, file_z.len - 1);
        @memcpy(file_z[0..fl], filename[0..fl]);
        file_z[fl] = 0;

        const val = c.JS_Eval(ctx, &code_z, cl, &file_z, c.JS_EVAL_TYPE_GLOBAL);
        defer c.JS_FreeValue(ctx, val);

        if (c.qjs_is_exception(val) != 0) {
            printException(ctx, self);
            return;
        }

        if (c.qjs_is_undefined(val) == 0) {
            const str = c.JS_ToCString(ctx, val);
            if (str != null) {
                self.pushOutput("\x1b[0;37m");
                const slice = cStrToSlice(str);
                self.pushOutput(slice);
                self.pushOutput("\x1b[0m\r\n");
                c.JS_FreeCString(ctx, str);
            }
        }
    }

    fn execFile(ctx: *c.JSContext, self: *JsRuntime, path: []const u8) void {
        const file = std.fs.cwd().openFile(path, .{}) catch {
            self.pushOutputFmt("\x1b[1;31mError:\x1b[0m could not open {s}\r\n", .{path});
            return;
        };
        defer file.close();

        // Wrap in IIFE so each script gets its own scope (no global leakage)
        const prefix = "(function(){";
        const suffix = "\n})();";
        var buf: [32768 + 32]u8 = undefined;
        @memcpy(buf[0..prefix.len], prefix);
        const n = file.readAll(buf[prefix.len .. buf.len - suffix.len]) catch {
            self.pushOutputFmt("\x1b[1;31mError:\x1b[0m could not read {s}\r\n", .{path});
            return;
        };
        @memcpy(buf[prefix.len + n ..][0..suffix.len], suffix);
        const total = prefix.len + n + suffix.len;

        execCode(ctx, self, buf[0..total], path);
    }

    fn printException(ctx: *c.JSContext, self: *JsRuntime) void {
        const ex = c.JS_GetException(ctx);
        defer c.JS_FreeValue(ctx, ex);

        const str = c.JS_ToCString(ctx, ex);
        if (str != null) {
            self.pushOutput("\x1b[1;31m");
            self.pushOutput(cStrToSlice(str));
            self.pushOutput("\x1b[0m\r\n");
            c.JS_FreeCString(ctx, str);
        }

        if (c.qjs_is_object(ex) != 0) {
            const stack = c.JS_GetPropertyStr(ctx, ex, "stack");
            defer c.JS_FreeValue(ctx, stack);
            if (c.qjs_is_undefined(stack) == 0) {
                const stack_str = c.JS_ToCString(ctx, stack);
                if (stack_str != null) {
                    self.pushOutput("\x1b[0;31m");
                    self.pushOutput(cStrToSlice(stack_str));
                    self.pushOutput("\x1b[0m\r\n");
                    c.JS_FreeCString(ctx, stack_str);
                }
            }
        }
    }

    // ---------------------------------------------------------------
    // Built-in JS functions (called from worker thread)
    // ---------------------------------------------------------------

    fn registerBuiltins(ctx: *c.JSContext, self: *JsRuntime) void {
        const global = c.JS_GetGlobalObject(ctx);
        defer c.JS_FreeValue(ctx, global);

        _ = c.JS_SetPropertyStr(ctx, global, "print", c.JS_NewCFunction(ctx, jsPrint, "print", 1));
        _ = c.JS_SetPropertyStr(ctx, global, "clear", c.JS_NewCFunction(ctx, jsClear, "clear", 0));
        _ = c.JS_SetPropertyStr(ctx, global, "sleep", c.JS_NewCFunction(ctx, jsSleep, "sleep", 1));

        // term object
        const term_obj = c.JS_NewObject(ctx);
        _ = c.JS_SetPropertyStr(ctx, term_obj, "write", c.JS_NewCFunction(ctx, jsTermWrite, "write", 1));
        _ = c.JS_SetPropertyStr(ctx, term_obj, "cursor", c.JS_NewCFunction(ctx, jsTermCursor, "cursor", 2));
        _ = c.JS_SetPropertyStr(ctx, term_obj, "color", c.JS_NewCFunction(ctx, jsTermColor, "color", 1));
        _ = c.JS_SetPropertyStr(ctx, term_obj, "reset", c.JS_NewCFunction(ctx, jsTermReset, "reset", 0));
        _ = c.JS_SetPropertyStr(ctx, term_obj, "cols", c.JS_NewInt32(ctx, @intCast(self.term.cols)));
        _ = c.JS_SetPropertyStr(ctx, term_obj, "rows", c.JS_NewInt32(ctx, @intCast(self.term.rows)));
        _ = c.JS_SetPropertyStr(ctx, term_obj, "rawMode", c.JS_NewCFunction(ctx, jsTermRawMode, "rawMode", 1));
        _ = c.JS_SetPropertyStr(ctx, term_obj, "getKey", c.JS_NewCFunction(ctx, jsTermGetKey, "getKey", 0));
        _ = c.JS_SetPropertyStr(ctx, global, "term", term_obj);

        // fs object
        const fs_obj = c.JS_NewObject(ctx);
        _ = c.JS_SetPropertyStr(ctx, fs_obj, "readFile", c.JS_NewCFunction(ctx, jsFsReadFile, "readFile", 1));
        _ = c.JS_SetPropertyStr(ctx, fs_obj, "writeFile", c.JS_NewCFunction(ctx, jsFsWriteFile, "writeFile", 2));
        _ = c.JS_SetPropertyStr(ctx, fs_obj, "listDir", c.JS_NewCFunction(ctx, jsFsListDir, "listDir", 1));
        _ = c.JS_SetPropertyStr(ctx, fs_obj, "exists", c.JS_NewCFunction(ctx, jsFsExists, "exists", 1));
        _ = c.JS_SetPropertyStr(ctx, global, "fs", fs_obj);
    }

    fn getSelf(ctx: ?*c.JSContext) *JsRuntime {
        const ptr = c.JS_GetContextOpaque(ctx);
        return @ptrCast(@alignCast(ptr));
    }

    fn jsPrint(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        const self = getSelf(ctx);
        var i: c_int = 0;
        while (i < argc) : (i += 1) {
            if (i > 0) self.pushOutput(" ");
            const str = c.JS_ToCString(ctx, argv[@intCast(i)]);
            if (str != null) {
                self.pushOutput(cStrToSlice(str));
                c.JS_FreeCString(ctx, str);
            }
        }
        self.pushOutput("\r\n");
        return c.qjs_undefined();
    }

    fn jsClear(ctx: ?*c.JSContext, _: c.JSValue, _: c_int, _: [*c]c.JSValue) callconv(.c) c.JSValue {
        const self = getSelf(ctx);
        self.pushOutput("\x1b[2J\x1b[H");
        return c.qjs_undefined();
    }

    fn jsSleep(_: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        if (argc >= 1) {
            var ms: i32 = 0;
            _ = c.JS_ToInt32(null, &ms, argv[0]);
            if (ms > 0 and ms < 30000) {
                std.time.sleep(@as(u64, @intCast(ms)) * std.time.ns_per_ms);
            }
        }
        return c.qjs_undefined();
    }

    fn jsTermWrite(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        const self = getSelf(ctx);
        if (argc >= 1) {
            const str = c.JS_ToCString(ctx, argv[0]);
            if (str != null) {
                self.pushOutput(cStrToSlice(str));
                c.JS_FreeCString(ctx, str);
            }
        }
        return c.qjs_undefined();
    }

    fn jsTermCursor(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        const self = getSelf(ctx);
        if (argc >= 2) {
            var row: i32 = 0;
            var col: i32 = 0;
            _ = c.JS_ToInt32(ctx, &row, argv[0]);
            _ = c.JS_ToInt32(ctx, &col, argv[1]);
            self.pushOutputFmt("\x1b[{d};{d}H", .{ row, col });
        }
        return c.qjs_undefined();
    }

    fn jsTermColor(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        const self = getSelf(ctx);
        if (argc >= 1) {
            const str = c.JS_ToCString(ctx, argv[0]);
            if (str != null) {
                const color = cStrToSlice(str);
                if (std.mem.eql(u8, color, "red")) {
                    self.pushOutput("\x1b[1;31m");
                } else if (std.mem.eql(u8, color, "green")) {
                    self.pushOutput("\x1b[1;32m");
                } else if (std.mem.eql(u8, color, "yellow")) {
                    self.pushOutput("\x1b[1;33m");
                } else if (std.mem.eql(u8, color, "blue")) {
                    self.pushOutput("\x1b[1;34m");
                } else if (std.mem.eql(u8, color, "magenta")) {
                    self.pushOutput("\x1b[1;35m");
                } else if (std.mem.eql(u8, color, "cyan")) {
                    self.pushOutput("\x1b[1;36m");
                } else if (std.mem.eql(u8, color, "white")) {
                    self.pushOutput("\x1b[1;37m");
                } else {
                    self.pushOutput("\x1b[");
                    self.pushOutput(color);
                    self.pushOutput("m");
                }
                c.JS_FreeCString(ctx, str);
            }
        }
        return c.qjs_undefined();
    }

    fn jsTermReset(ctx: ?*c.JSContext, _: c.JSValue, _: c_int, _: [*c]c.JSValue) callconv(.c) c.JSValue {
        const self = getSelf(ctx);
        self.pushOutput("\x1b[0m");
        return c.qjs_undefined();
    }

    /// term.rawMode(bool) — enable/disable raw key input for interactive programs
    fn jsTermRawMode(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        const self = getSelf(ctx);
        if (argc >= 1) {
            var val: c_int = 0;
            _ = c.JS_ToInt32(ctx, &val, argv[0]);
            self.term.raw_mode = val != 0;
            // Clear key queue on mode change
            self.term.key_mutex.lock();
            self.term.key_queue_len = 0;
            self.term.key_mutex.unlock();
        }
        return c.qjs_undefined();
    }

    /// term.getKey() — blocking read of a key/sequence. Returns string.
    /// Returns: single char for printable, "enter"/"backspace"/"escape"/"delete"/"tab" for specials,
    /// "up"/"down"/"left"/"right"/"home"/"end"/"pageup"/"pagedown" for nav,
    /// "ctrl-s"/"ctrl-q"/etc for ctrl combos, "" if nothing (shouldn't happen).
    fn jsTermGetKey(ctx: ?*c.JSContext, _: c.JSValue, _: c_int, _: [*c]c.JSValue) callconv(.c) c.JSValue {
        const self = getSelf(ctx);

        // Block until we get a key (poll every 10ms)
        var key_buf: [8]u8 = undefined;
        var key_len: usize = 0;
        while (key_len == 0) {
            if (self.shutdown.load(.acquire)) return c.qjs_null();
            key_len = self.term.readKeySeq(&key_buf);
            if (key_len == 0) std.time.sleep(10 * std.time.ns_per_ms);
        }

        // Translate to a friendly string
        const result: []const u8 = blk: {
            if (key_len == 1) {
                break :blk switch (key_buf[0]) {
                    13 => "enter",
                    8 => "backspace",
                    9 => "tab",
                    27 => "escape",
                    127 => "delete",
                    7 => "ctrl-g",
                    11 => "ctrl-k",
                    15 => "ctrl-o",
                    17 => "ctrl-q",
                    19 => "ctrl-s",
                    23 => "ctrl-w",
                    24 => "ctrl-x",
                    else => &.{key_buf[0]}, // printable char
                };
            }
            if (key_len >= 3 and key_buf[0] == 27 and key_buf[1] == '[') {
                break :blk switch (key_buf[2]) {
                    'A' => "up",
                    'B' => "down",
                    'C' => "right",
                    'D' => "left",
                    'H' => "home",
                    'F' => "end",
                    '5' => "pageup",
                    '6' => "pagedown",
                    else => "unknown",
                };
            }
            break :blk "unknown";
        };

        return c.JS_NewStringLen(ctx, result.ptr, result.len);
    }

    // ---------------------------------------------------------------
    // Filesystem functions (run on worker thread, no terminal access)
    // ---------------------------------------------------------------

    fn jsFsReadFile(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        if (argc < 1) return c.qjs_null();
        const path_c = c.JS_ToCString(ctx, argv[0]);
        if (path_c == null) return c.qjs_null();
        defer c.JS_FreeCString(ctx, path_c);
        const path = cStrToSlice(path_c);

        const file = std.fs.cwd().openFile(path, .{}) catch return c.qjs_null();
        defer file.close();

        var buf: [65536]u8 = undefined;
        const n = file.readAll(&buf) catch return c.qjs_null();

        return c.JS_NewStringLen(ctx, &buf, n);
    }

    fn jsFsWriteFile(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        if (argc < 2) return c.qjs_false();
        const path_c = c.JS_ToCString(ctx, argv[0]);
        if (path_c == null) return c.qjs_false();
        defer c.JS_FreeCString(ctx, path_c);
        const path = cStrToSlice(path_c);

        const content_c = c.JS_ToCString(ctx, argv[1]);
        if (content_c == null) return c.qjs_false();
        defer c.JS_FreeCString(ctx, content_c);
        const content = cStrToSlice(content_c);

        const file = std.fs.cwd().createFile(path, .{}) catch return c.qjs_false();
        defer file.close();
        file.writeAll(content) catch return c.qjs_false();

        return c.qjs_true();
    }

    fn jsFsListDir(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        if (argc < 1) return c.qjs_null();
        const path_c = c.JS_ToCString(ctx, argv[0]);
        if (path_c == null) return c.qjs_null();
        defer c.JS_FreeCString(ctx, path_c);
        const path = cStrToSlice(path_c);

        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return c.qjs_null();
        defer dir.close();

        const arr = c.JS_NewArray(ctx);
        var idx: u32 = 0;
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            const name = entry.name;
            const js_str = c.JS_NewStringLen(ctx, name.ptr, name.len);
            _ = c.JS_SetPropertyUint32(ctx, arr, idx, js_str);
            idx += 1;
            if (idx >= 1000) break;
        }

        return arr;
    }

    fn jsFsExists(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        if (argc < 1) return c.qjs_false();
        const path_c = c.JS_ToCString(ctx, argv[0]);
        if (path_c == null) return c.qjs_false();
        defer c.JS_FreeCString(ctx, path_c);
        const path = cStrToSlice(path_c);

        std.fs.cwd().access(path, .{}) catch return c.qjs_false();
        return c.qjs_true();
    }
};

fn cStrToSlice(cstr: [*c]const u8) []const u8 {
    var len: usize = 0;
    while (cstr[len] != 0) : (len += 1) {}
    return cstr[0..len];
}
