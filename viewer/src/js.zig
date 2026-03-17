const std = @import("std");
const terminal_mod = @import("terminal.zig");
const display_mod = @import("display.zig");

pub const c = @cImport({
    @cInclude("quickjs.h");
    @cInclude("quickjs-zig-helpers.h");
    @cInclude("pty-helpers.h");
});

const MAX_OUTPUT: usize = 64 * 1024;
const MAX_JOBS: usize = 16;
pub const MAX_PIPE_STAGES: usize = 8;

pub const JobStage = struct {
    code: [32768]u8 = undefined,
    code_len: usize = 0,
    filename: [256]u8 = undefined,
    filename_len: usize = 0,
    is_file: bool = false,
};

pub const Job = struct {
    stages: [MAX_PIPE_STAGES]JobStage = undefined,
    stage_count: usize = 1,
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

    // C-visible flags for QuickJS interrupt handler
    c_shutdown_flag: c_int = 0,
    c_interrupt_flag: c_int = 0, // set by Ctrl+C, cleared after interrupt

    // Command history for readLine
    history: [128][1024]u8 = undefined,
    history_lens: [128]u16 = .{0} ** 128,
    history_count: usize = 0,
    history_head: usize = 0, // write position (ring buffer)

    // Capture mode for pipe stages (worker thread only — no mutex needed)
    capturing: bool = false,
    capture_buf: [MAX_OUTPUT]u8 = undefined,
    capture_len: usize = 0,

    // Terminal ref (for reading dimensions — main thread only for actual writes)
    term: *terminal_mod.Terminal = undefined,

    // Display manager for graphics API (heap-allocated ring buffer)
    display_mgr: display_mod.DisplayManager = undefined,
    display_mgr_init: bool = false,

    const history_path = ".cassandra_history";

    pub fn init(self: *JsRuntime, term: *terminal_mod.Terminal) void {
        self.term = term;
        self.display_mgr = display_mod.DisplayManager.init(std.heap.page_allocator);
        self.display_mgr_init = true;
        self.shutdown.store(false, .release);
        self.loadHistory();
        self.worker = std.Thread.spawn(.{}, workerLoop, .{self}) catch null;
    }

    pub fn deinit(self: *JsRuntime) void {
        self.shutdown.store(true, .release);
        self.c_shutdown_flag = 1; // signal QuickJS interrupt handler
        // Unblock readLine/getKey by pushing Enter so they return
        self.term.key_mutex.lock();
        self.term.pushKey(13);
        self.term.pushKey(0);
        self.term.key_mutex.unlock();
        if (self.worker) |w| {
            w.join();
            self.worker = null;
        }
        if (self.display_mgr_init) {
            self.display_mgr.deinit();
            self.display_mgr_init = false;
        }
    }

    /// Submit inline JS code for execution on the worker thread.
    pub fn eval(self: *JsRuntime, code: []const u8, filename: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.job_count >= MAX_JOBS) return;

        var job = &self.jobs[self.job_count];
        job.stage_count = 1;
        var stage = &job.stages[0];
        stage.is_file = false;
        const cl = @min(code.len, stage.code.len - 1);
        @memcpy(stage.code[0..cl], code[0..cl]);
        stage.code_len = cl;
        const fl = @min(filename.len, stage.filename.len - 1);
        @memcpy(stage.filename[0..fl], filename[0..fl]);
        stage.filename_len = fl;
        self.job_count += 1;
    }

    /// Submit a JS file for execution on the worker thread.
    pub fn evalFile(self: *JsRuntime, path: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.job_count >= MAX_JOBS) return;

        var job = &self.jobs[self.job_count];
        job.stage_count = 1;
        var stage = &job.stages[0];
        stage.is_file = true;
        const pl = @min(path.len, stage.filename.len - 1);
        @memcpy(stage.filename[0..pl], path[0..pl]);
        stage.filename_len = pl;
        stage.code_len = 0;
        self.job_count += 1;
    }

    /// Submit a multi-stage pipeline job.
    pub fn submitPipeline(self: *JsRuntime, job: Job) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.job_count >= MAX_JOBS) return;
        self.jobs[self.job_count] = job;
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

    /// Push output bytes from the worker thread.
    /// In capture mode, goes to capture buffer; otherwise to terminal output.
    fn pushOutput(self: *JsRuntime, data: []const u8) void {
        if (self.capturing) {
            const avail = MAX_OUTPUT - self.capture_len;
            const n = @min(data.len, avail);
            if (n > 0) {
                @memcpy(self.capture_buf[self.capture_len..][0..n], data[0..n]);
                self.capture_len += n;
            }
            return;
        }
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

        // Set interrupt handler to abort long-running JS on shutdown
        c.qjs_set_interrupt_flag(rt, &self.c_shutdown_flag);

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

                // Execute pipeline stages
                var stdin_data: [MAX_OUTPUT]u8 = undefined;
                var stdin_len: usize = 0;

                for (0..j.stage_count) |si| {
                    const stage = j.stages[si];
                    const is_last = (si == j.stage_count - 1);

                    // Set __stdin and __piped globals
                    {
                        var js_code: [MAX_OUTPUT + 128]u8 = undefined;
                        // Escape the stdin content for JS string
                        const stdin_slice = stdin_data[0..stdin_len];
                        const set_code = std.fmt.bufPrint(&js_code, "globalThis.__piped = {s}; globalThis.__stdin = globalThis.__piped ? globalThis.__stdin : \"\";", .{if (stdin_len > 0) "true" else "false"}) catch "";
                        if (set_code.len > 0) execCode(ctx, self, set_code, "<pipe>");

                        // Set stdin via a separate mechanism — store as a property
                        if (stdin_len > 0) {
                            const global = c.JS_GetGlobalObject(ctx);
                            const js_str = c.JS_NewStringLen(ctx, &stdin_data, stdin_len);
                            _ = c.JS_SetPropertyStr(ctx, global, "__stdin", js_str);
                            c.JS_FreeValue(ctx, global);
                        } else {
                            const global = c.JS_GetGlobalObject(ctx);
                            _ = c.JS_SetPropertyStr(ctx, global, "__stdin", c.JS_NewStringLen(ctx, "", 0));
                            c.JS_FreeValue(ctx, global);
                        }
                        _ = stdin_slice;
                    }

                    // Capture mode for non-last stages
                    self.capturing = !is_last;
                    self.capture_len = 0;

                    // Run args setup code if present
                    if (stage.code_len > 0) {
                        execCode(ctx, self, stage.code[0..stage.code_len], "<args>");
                    }

                    if (stage.is_file) {
                        execFile(ctx, self, stage.filename[0..stage.filename_len]);
                    } else if (stage.code_len > 0 and !stage.is_file) {
                        // Already ran as code above
                    } else {
                        execCode(ctx, self, stage.code[0..stage.code_len], stage.filename[0..stage.filename_len]);
                    }

                    // Collect captured output as stdin for next stage
                    if (!is_last) {
                        const copy_len = @min(self.capture_len, stdin_data.len);
                        @memcpy(stdin_data[0..copy_len], self.capture_buf[0..copy_len]);
                        stdin_len = copy_len;
                    }
                    self.capturing = false;
                }

                // Clear interrupt flag and clean up displays after execution
                if (self.c_interrupt_flag != 0) {
                    self.pushOutput("\x1b[1;33m^C\x1b[0m\r\n");
                    self.c_interrupt_flag = 0;
                    // Close any displays left open by the interrupted program
                    for (&self.display_mgr.displays) |*d| {
                        d.active = false;
                    }
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
        _ = c.JS_SetPropertyStr(ctx, term_obj, "readLine", c.JS_NewCFunction(ctx, jsTermReadLine, "readLine", 0));
        _ = c.JS_SetPropertyStr(ctx, global, "term", term_obj);

        // exec(filename, capture?) — run a JS file in its own scope
        _ = c.JS_SetPropertyStr(ctx, global, "exec", c.JS_NewCFunction(ctx, jsExec, "exec", 2));

        // system(cmd) — run a host binary with PTY
        _ = c.JS_SetPropertyStr(ctx, global, "system", c.JS_NewCFunction(ctx, jsSystem, "system", 1));

        // fs object
        const fs_obj = c.JS_NewObject(ctx);
        _ = c.JS_SetPropertyStr(ctx, fs_obj, "readFile", c.JS_NewCFunction(ctx, jsFsReadFile, "readFile", 1));
        _ = c.JS_SetPropertyStr(ctx, fs_obj, "writeFile", c.JS_NewCFunction(ctx, jsFsWriteFile, "writeFile", 2));
        _ = c.JS_SetPropertyStr(ctx, fs_obj, "listDir", c.JS_NewCFunction(ctx, jsFsListDir, "listDir", 1));
        _ = c.JS_SetPropertyStr(ctx, fs_obj, "exists", c.JS_NewCFunction(ctx, jsFsExists, "exists", 1));
        _ = c.JS_SetPropertyStr(ctx, global, "fs", fs_obj);

        // gfx object — graphics display API
        const gfx_obj = c.JS_NewObject(ctx);
        _ = c.JS_SetPropertyStr(ctx, gfx_obj, "create", c.JS_NewCFunction(ctx, jsGfxCreate, "create", 3));
        _ = c.JS_SetPropertyStr(ctx, gfx_obj, "destroy", c.JS_NewCFunction(ctx, jsGfxDestroy, "destroy", 1));
        _ = c.JS_SetPropertyStr(ctx, gfx_obj, "move", c.JS_NewCFunction(ctx, jsGfxMove, "move", 3));
        _ = c.JS_SetPropertyStr(ctx, gfx_obj, "begin", c.JS_NewCFunction(ctx, jsGfxBegin, "begin", 1));
        _ = c.JS_SetPropertyStr(ctx, gfx_obj, "end", c.JS_NewCFunction(ctx, jsGfxEnd, "end", 1));
        _ = c.JS_SetPropertyStr(ctx, gfx_obj, "clear", c.JS_NewCFunction(ctx, jsGfxClear, "clear", 3));
        _ = c.JS_SetPropertyStr(ctx, gfx_obj, "line", c.JS_NewCFunction(ctx, jsGfxLine, "line", 6));
        _ = c.JS_SetPropertyStr(ctx, gfx_obj, "rect", c.JS_NewCFunction(ctx, jsGfxRect, "rect", 5));
        _ = c.JS_SetPropertyStr(ctx, gfx_obj, "rectLines", c.JS_NewCFunction(ctx, jsGfxRectLines, "rectLines", 5));
        _ = c.JS_SetPropertyStr(ctx, gfx_obj, "circle", c.JS_NewCFunction(ctx, jsGfxCircle, "circle", 4));
        _ = c.JS_SetPropertyStr(ctx, gfx_obj, "triangle", c.JS_NewCFunction(ctx, jsGfxTriangle, "triangle", 7));
        _ = c.JS_SetPropertyStr(ctx, gfx_obj, "text", c.JS_NewCFunction(ctx, jsGfxText, "text", 5));
        _ = c.JS_SetPropertyStr(ctx, gfx_obj, "cube", c.JS_NewCFunction(ctx, jsGfxCube, "cube", 7));
        _ = c.JS_SetPropertyStr(ctx, gfx_obj, "line3d", c.JS_NewCFunction(ctx, jsGfxLine3d, "line3d", 7));
        _ = c.JS_SetPropertyStr(ctx, gfx_obj, "camera", c.JS_NewCFunction(ctx, jsGfxCamera, "camera", 4));
        _ = c.JS_SetPropertyStr(ctx, gfx_obj, "begin3d", c.JS_NewCFunction(ctx, jsGfxBegin3d, "begin3d", 7));
        _ = c.JS_SetPropertyStr(ctx, gfx_obj, "end3d", c.JS_NewCFunction(ctx, jsGfxEnd3d, "end3d", 0));
        _ = c.JS_SetPropertyStr(ctx, gfx_obj, "triangle3d", c.JS_NewCFunction(ctx, jsGfxTriangle3d, "triangle3d", 10));
        _ = c.JS_SetPropertyStr(ctx, gfx_obj, "solidCube", c.JS_NewCFunction(ctx, jsGfxSolidCube, "solidCube", 10));
        _ = c.JS_SetPropertyStr(ctx, gfx_obj, "rgb", c.JS_NewCFunction(ctx, jsGfxRgb, "rgb", 3));
        _ = c.JS_SetPropertyStr(ctx, gfx_obj, "rgba", c.JS_NewCFunction(ctx, jsGfxRgba, "rgba", 4));
        _ = c.JS_SetPropertyStr(ctx, global, "gfx", gfx_obj);
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

    fn jsSleep(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        if (argc >= 1) {
            const self = getSelf(ctx);
            var ms: i32 = 0;
            _ = c.JS_ToInt32(null, &ms, argv[0]);
            if (ms > 0 and ms < 30000) {
                // Sleep in small chunks so Ctrl+C is responsive
                var remaining: u64 = @intCast(ms);
                while (remaining > 0 and self.c_interrupt_flag == 0 and !self.shutdown.load(.acquire)) {
                    const chunk: u64 = @min(remaining, 10);
                    std.time.sleep(chunk * @as(u64, std.time.ns_per_ms));
                    remaining -= chunk;
                }
                // If interrupted during sleep, kill all displays immediately
                if (self.c_interrupt_flag != 0) {
                    for (&self.display_mgr.displays) |*d| {
                        d.active = false;
                    }
                }
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

    /// term.readLine() — blocking line input with echo, editing, and history. Returns string.
    fn jsTermReadLine(ctx: ?*c.JSContext, _: c.JSValue, _: c_int, _: [*c]c.JSValue) callconv(.c) c.JSValue {
        const self = getSelf(ctx);
        const trm = self.term;

        const was_raw = trm.raw_mode;
        trm.raw_mode = true;
        trm.key_mutex.lock();
        trm.key_queue_len = 0;
        trm.key_mutex.unlock();

        var buf: [1024]u8 = undefined;
        var len: usize = 0;
        var pos: usize = 0; // cursor position within buf
        var hist_idx: isize = -1;
        var saved_buf: [1024]u8 = undefined;
        var saved_len: usize = 0;

        while (!self.shutdown.load(.acquire)) {
            // Check for Ctrl+C interrupt
            if (self.c_interrupt_flag != 0) {
                self.pushOutput("^C\r\n");
                self.c_interrupt_flag = 0;
                trm.raw_mode = was_raw;
                return c.JS_NewStringLen(ctx, "", 0);
            }

            const ch = trm.readKey();
            if (ch == 0) {
                std.time.sleep(10 * std.time.ns_per_ms);
                continue;
            }

            switch (ch) {
                3 => { // Ctrl+C received as key
                    self.pushOutput("^C\r\n");
                    self.c_interrupt_flag = 1; // trigger QuickJS interrupt
                    trm.raw_mode = was_raw;
                    return c.JS_NewStringLen(ctx, "", 0);
                },
                13 => { // Enter
                    self.moveCursorRight(buf[0..len], pos, len - pos);
                    self.pushOutput("\r\n");
                    if (len > 0) self.addHistory(buf[0..len]);
                    break;
                },
                8 => { // Backspace
                    if (pos > 0) {
                        std.mem.copyForwards(u8, buf[pos - 1 .. len - 1], buf[pos..len]);
                        pos -= 1;
                        len -= 1;
                        if (pos == len) {
                            // Simple case: backspace at end of line
                            self.pushOutput("\x08 \x08");
                        } else {
                            // Middle of line: rewrite from cursor
                            self.pushOutput("\x08");
                            self.pushOutput(buf[pos..len]);
                            self.pushOutput(" "); // clear last char
                            // Move cursor back to pos
                            self.moveCursorLeft(len - pos + 1);
                        }
                    }
                },
                127 => { // Delete
                    if (pos < len) {
                        std.mem.copyForwards(u8, buf[pos .. len - 1], buf[pos + 1 .. len]);
                        len -= 1;
                        // Rewrite from cursor to end
                        self.pushOutput(buf[pos..len]);
                        self.pushOutput(" ");
                        self.moveCursorLeft(len - pos + 1);
                    }
                },
                1 => { // Ctrl-A — home
                    self.moveCursorLeft(pos);
                    pos = 0;
                },
                5 => { // Ctrl-E — end
                    self.moveCursorRight(buf[0..len], pos, len - pos);
                    pos = len;
                },
                27 => { // ESC — start of escape sequence
                    // Read CSI sequence without sleeping (check queue immediately)
                    const b2 = trm.readKey();
                    if (b2 == '[') {
                        const b3 = trm.readKey();
                        if (b3 == '1') {
                            // Modifier sequence: CSI 1;5 C/D
                            const b4 = trm.readKey();
                            if (b4 == ';') {
                                const b5 = trm.readKey();
                                if (b5 == '5') {
                                    const b6 = trm.readKey();
                                    switch (b6) {
                                        'D' => { // Ctrl+Left
                                            if (pos > 0) {
                                                var p = pos;
                                                while (p > 0 and buf[p - 1] == ' ') p -= 1;
                                                while (p > 0 and buf[p - 1] != ' ') p -= 1;
                                                self.moveCursorLeft(pos - p);
                                                pos = p;
                                            }
                                        },
                                        'C' => { // Ctrl+Right
                                            if (pos < len) {
                                                var p = pos;
                                                while (p < len and buf[p] != ' ') p += 1;
                                                while (p < len and buf[p] == ' ') p += 1;
                                                self.moveCursorRight(buf[0..len], pos, p - pos);
                                                pos = p;
                                            }
                                        },
                                        else => {},
                                    }
                                }
                            }
                        } else {
                            switch (b3) {
                                'A' => { // Up
                                    const max_idx: isize = @intCast(self.history_count);
                                    if (hist_idx + 1 < max_idx) {
                                        if (hist_idx == -1) {
                                            @memcpy(saved_buf[0..len], buf[0..len]);
                                            saved_len = len;
                                        }
                                        hist_idx += 1;
                                        self.loadHistoryRL(hist_idx, &buf, &len, &pos);
                                    }
                                },
                                'B' => { // Down
                                    if (hist_idx > 0) {
                                        hist_idx -= 1;
                                        self.loadHistoryRL(hist_idx, &buf, &len, &pos);
                                    } else if (hist_idx == 0) {
                                        hist_idx = -1;
                                        self.eraseLineFrom(pos, len);
                                        @memcpy(buf[0..saved_len], saved_buf[0..saved_len]);
                                        len = saved_len;
                                        pos = len;
                                        self.pushOutput(buf[0..len]);
                                    }
                                },
                                'C' => { // Right
                                    if (pos < len) {
                                        self.pushOutput(buf[pos .. pos + 1]);
                                        pos += 1;
                                    }
                                },
                                'D' => { // Left
                                    if (pos > 0) {
                                        self.pushOutput("\x08");
                                        pos -= 1;
                                    }
                                },
                                'H' => { // Home
                                    self.moveCursorLeft(pos);
                                    pos = 0;
                                },
                                'F' => { // End
                                    self.moveCursorRight(buf[0..len], pos, len - pos);
                                    pos = len;
                                },
                                else => {},
                            }
                        }
                    }
                    // else: bare ESC — ignore
                },
                else => {
                    if (ch >= 32 and ch < 127 and len < buf.len) {
                        if (pos < len) {
                            std.mem.copyBackwards(u8, buf[pos + 1 .. len + 1], buf[pos..len]);
                        }
                        buf[pos] = ch;
                        len += 1;
                        pos += 1;
                        if (pos == len) {
                            // Appending at end
                            self.pushOutput(buf[pos - 1 .. pos]);
                        } else {
                            // Inserted in middle — rewrite from insert point
                            self.pushOutput(buf[pos - 1 .. len]);
                            self.moveCursorLeft(len - pos);
                        }
                    }
                },
            }
        }

        trm.raw_mode = was_raw;
        return c.JS_NewStringLen(ctx, &buf, len);
    }

    /// Move cursor left n positions
    fn moveCursorLeft(self: *JsRuntime, n: usize) void {
        var i: usize = 0;
        while (i < n) : (i += 1) self.pushOutput("\x08");
    }

    /// Move cursor right by outputting the characters under cursor
    fn moveCursorRight(self: *JsRuntime, buf: []const u8, from: usize, n: usize) void {
        if (n > 0 and from + n <= buf.len) {
            self.pushOutput(buf[from .. from + n]);
        }
    }

    /// Redraw line from cursor position, clear any leftover chars, reposition cursor
    fn redrawFrom(self: *JsRuntime, buf: []const u8, pos: usize, old_len: usize) void {
        // Move cursor to pos
        // (we're already at pos on screen after backspace/insert)
        // Write from pos to end
        if (pos < buf.len) {
            self.pushOutput(buf[pos..buf.len]);
        }
        // Clear any leftover characters from old longer content
        if (old_len > buf.len) {
            var i: usize = 0;
            while (i < old_len - buf.len) : (i += 1) self.pushOutput(" ");
            i = 0;
            while (i < old_len - buf.len) : (i += 1) self.pushOutput("\x08");
        }
        // Move cursor back to pos
        const chars_after = buf.len - pos;
        self.moveCursorLeft(chars_after);
    }

    /// Erase line from cursor position to end, for history loading
    fn eraseLineFrom(self: *JsRuntime, pos: usize, len: usize) void {
        // Move cursor to start
        self.moveCursorLeft(pos);
        // Overwrite with spaces
        var i: usize = 0;
        while (i < len) : (i += 1) self.pushOutput(" ");
        // Move back to start
        self.moveCursorLeft(len);
    }

    fn loadHistoryRL(self: *JsRuntime, idx: isize, buf: *[1024]u8, len: *usize, pos: *usize) void {
        if (idx < 0 or idx >= @as(isize, @intCast(self.history_count))) return;
        const ui: usize = @intCast(idx);
        const actual = (self.history_head + self.history.len - 1 - ui) % self.history.len;
        const hlen = self.history_lens[actual];

        self.eraseLineFrom(pos.*, len.*);
        @memcpy(buf[0..hlen], self.history[actual][0..hlen]);
        len.* = hlen;
        pos.* = hlen;
        self.pushOutput(buf[0..len.*]);
    }

    fn addHistory(self: *JsRuntime, line: []const u8) void {
        const idx = self.history_head;
        const copy_len = @min(line.len, self.history[idx].len);
        @memcpy(self.history[idx][0..copy_len], line[0..copy_len]);
        self.history_lens[idx] = @intCast(copy_len);
        self.history_head = (self.history_head + 1) % self.history.len;
        if (self.history_count < self.history.len) self.history_count += 1;
        self.saveHistory();
    }

    /// Load command history from disk.
    fn loadHistory(self: *JsRuntime) void {
        const file = std.fs.cwd().openFile(history_path, .{}) catch return;
        defer file.close();
        const reader = file.reader();

        // Read number of entries
        const count = reader.readInt(u32, .little) catch return;
        if (count == 0 or count > self.history.len) return;

        for (0..count) |_| {
            const len = reader.readInt(u16, .little) catch return;
            if (len > 1024) return;
            const idx = self.history_head;
            reader.readNoEof(self.history[idx][0..len]) catch return;
            self.history_lens[idx] = len;
            self.history_head = (self.history_head + 1) % self.history.len;
            if (self.history_count < self.history.len) self.history_count += 1;
        }
    }

    /// Save command history to disk.
    fn saveHistory(self: *JsRuntime) void {
        const file = std.fs.cwd().createFile(history_path, .{}) catch return;
        defer file.close();
        const writer = file.writer();

        const count: u32 = @intCast(self.history_count);
        writer.writeInt(u32, count, .little) catch return;

        // Write entries oldest-first so loadHistory replays in order
        for (0..self.history_count) |i| {
            const actual = (self.history_head + self.history.len - self.history_count + i) % self.history.len;
            const len = self.history_lens[actual];
            writer.writeInt(u16, len, .little) catch return;
            writer.writeAll(self.history[actual][0..len]) catch return;
        }
    }


    /// exec(filename, capture?) — run a JS file in its own IIFE scope.
    /// If capture is truthy, returns all output as a string instead of sending to terminal.
    fn jsExec(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        if (argc < 1) return c.qjs_undefined();
        const real_ctx = ctx orelse return c.qjs_undefined();
        const path_c = c.JS_ToCString(real_ctx, argv[0]);
        if (path_c == null) return c.qjs_undefined();
        defer c.JS_FreeCString(real_ctx, path_c);
        const path = cStrToSlice(path_c);

        const self = getSelf(ctx);

        // Check capture flag
        var capture = false;
        if (argc >= 2) {
            var cap_val: c_int = 0;
            _ = c.JS_ToInt32(real_ctx, &cap_val, argv[1]);
            capture = cap_val != 0;
        }

        const file = std.fs.cwd().openFile(path, .{}) catch {
            self.pushOutputFmt("\x1b[1;31mError:\x1b[0m could not open {s}\r\n", .{path});
            if (capture) return c.qjs_null();
            return c.qjs_false();
        };
        defer file.close();

        const prefix = "(function(){";
        const suffix = "\n})();";
        var code_buf: [32768 + 32]u8 = undefined;
        @memcpy(code_buf[0..prefix.len], prefix);
        const n = file.readAll(code_buf[prefix.len .. code_buf.len - suffix.len]) catch {
            self.pushOutputFmt("\x1b[1;31mError:\x1b[0m could not read {s}\r\n", .{path});
            if (capture) return c.qjs_null();
            return c.qjs_false();
        };
        @memcpy(code_buf[prefix.len + n ..][0..suffix.len], suffix);
        const total = prefix.len + n + suffix.len;
        code_buf[total] = 0;

        var file_z: [256]u8 = undefined;
        const fl = @min(path.len, file_z.len - 1);
        @memcpy(file_z[0..fl], path[0..fl]);
        file_z[fl] = 0;

        // Enable capture mode
        if (capture) {
            self.capturing = true;
            self.capture_len = 0;
        }

        const val = c.JS_Eval(real_ctx, &code_buf, total, &file_z, c.JS_EVAL_TYPE_GLOBAL);
        defer c.JS_FreeValue(real_ctx, val);

        if (c.qjs_is_exception(val) != 0) {
            if (capture) self.capturing = false;

            // Build result object: {ok: false, reason: "interrupted"|"error", error: "...", stack: "..."}
            const ex = c.JS_GetException(real_ctx);
            defer c.JS_FreeValue(real_ctx, ex);

            const is_interrupt = self.c_interrupt_flag != 0;

            const result_obj = c.JS_NewObject(real_ctx);
            _ = c.JS_SetPropertyStr(real_ctx, result_obj, "ok", c.qjs_false());
            _ = c.JS_SetPropertyStr(real_ctx, result_obj, "reason",
                c.JS_NewString(real_ctx, if (is_interrupt) "interrupted" else "error"));

            // Attach error message
            const err_str = c.JS_ToCString(real_ctx, ex);
            if (err_str != null) {
                _ = c.JS_SetPropertyStr(real_ctx, result_obj, "error",
                    c.JS_NewString(real_ctx, err_str));
                c.JS_FreeCString(real_ctx, err_str);
            }

            // Attach stack trace
            if (c.qjs_is_object(ex) != 0) {
                const stack = c.JS_GetPropertyStr(real_ctx, ex, "stack");
                if (c.qjs_is_undefined(stack) == 0) {
                    _ = c.JS_SetPropertyStr(real_ctx, result_obj, "stack", stack);
                } else {
                    c.JS_FreeValue(real_ctx, stack);
                }
            }

            if (capture) return c.qjs_null();
            return result_obj;
        }

        // Return captured output
        if (capture) {
            self.capturing = false;
            const result = c.JS_NewStringLen(real_ctx, &self.capture_buf, self.capture_len);
            self.capture_len = 0;
            return result;
        }

        return c.qjs_true();
    }

    /// system(cmd) — spawn a host process with a PTY, pipe I/O through the terminal.
    /// Blocks until the process exits. Fully interactive (vi, ssh, etc.).
    fn jsSystem(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        if (argc < 1) return c.qjs_undefined();
        const real_ctx = ctx orelse return c.qjs_undefined();
        const cmd_c = c.JS_ToCString(real_ctx, argv[0]);
        if (cmd_c == null) return c.qjs_undefined();
        defer c.JS_FreeCString(real_ctx, cmd_c);

        const self = getSelf(ctx);
        const trm = self.term;

        // Enable raw mode so we get keystrokes
        const was_raw = trm.raw_mode;
        trm.raw_mode = true;
        trm.key_mutex.lock();
        trm.key_queue_len = 0;
        trm.key_mutex.unlock();

        // Spawn process with PTY
        var child_pid: c.pid_t = 0;
        const master_fd = c.pty_spawn(cmd_c, &child_pid);
        if (master_fd < 0) {
            self.pushOutput("\x1b[1;31mFailed to spawn process\x1b[0m\r\n");
            trm.raw_mode = was_raw;
            return c.qjs_false();
        }

        // Set PTY size to match our terminal
        c.pty_resize(master_fd, @intCast(trm.rows), @intCast(trm.cols));

        // I/O loop: shuttle data between PTY and terminal
        var read_buf: [4096]u8 = undefined;

        while (!self.shutdown.load(.acquire)) {
            // Read PTY output → terminal
            const n = c.pty_read(master_fd, &read_buf, read_buf.len);
            if (n > 0) {
                self.pushOutput(read_buf[0..@intCast(n)]);
            } else if (n < 0) {
                // Process closed
                break;
            }

            // Read terminal keys → PTY stdin
            while (true) {
                const key = trm.readKey();
                if (key == 0) break;
                const key_byte = [1]u8{key};
                _ = c.pty_write(master_fd, &key_byte, 1);
            }

            // Check if child is still alive
            if (c.pty_alive(child_pid) == 0) {
                // Drain remaining output
                while (true) {
                    const rem = c.pty_read(master_fd, &read_buf, read_buf.len);
                    if (rem <= 0) break;
                    self.pushOutput(read_buf[0..@intCast(rem)]);
                }
                break;
            }

            // Brief sleep to avoid spinning
            std.time.sleep(5 * std.time.ns_per_ms);
        }

        c.pty_close(master_fd, child_pid);
        trm.raw_mode = was_raw;
        return c.qjs_true();
    }

    // ---------------------------------------------------------------
    // Graphics display functions
    // ---------------------------------------------------------------

    fn getF(ctx: ?*c.JSContext, argv: [*c]c.JSValue, idx: usize) f32 {
        var v: f64 = 0;
        _ = c.JS_ToFloat64(ctx, &v, argv[idx]);
        return @floatCast(v);
    }

    fn getI(ctx: ?*c.JSContext, argv: [*c]c.JSValue, idx: usize) i32 {
        var v: i32 = 0;
        _ = c.JS_ToInt32(ctx, &v, argv[idx]);
        return v;
    }

    fn getU(ctx: ?*c.JSContext, argv: [*c]c.JSValue, idx: usize) u32 {
        var v: i64 = 0;
        _ = c.JS_ToInt64(ctx, &v, argv[idx]);
        return @intCast(@as(u64, @bitCast(v)) & 0xFFFFFFFF);
    }

    fn colorFromArgs(ctx: ?*c.JSContext, argv: [*c]c.JSValue, idx: usize) display_mod.Color4 {
        return display_mod.fromU32(getU(ctx, argv, idx));
    }

    fn pushGfx(self: *JsRuntime, cmd: display_mod.DrawCmd) void {
        self.display_mgr.ring.push(cmd);
    }

    fn jsGfxCreate(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        const self = getSelf(ctx);
        var cmd = display_mod.DrawCmd{ .tag = .create };
        cmd.display_id = if (argc >= 1) @intCast(@as(u32, @bitCast(getI(ctx, argv, 0))) & 3) else 0;
        cmd.f[0] = if (argc >= 2) getF(ctx, argv, 1) else 320;
        cmd.f[1] = if (argc >= 3) getF(ctx, argv, 2) else 240;
        self.pushGfx(cmd);
        return c.qjs_undefined();
    }

    fn jsGfxDestroy(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        const self = getSelf(ctx);
        var cmd = display_mod.DrawCmd{ .tag = .destroy };
        cmd.display_id = if (argc >= 1) @intCast(@as(u32, @bitCast(getI(ctx, argv, 0))) & 3) else 0;
        self.pushGfx(cmd);
        return c.qjs_undefined();
    }

    fn jsGfxMove(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        const self = getSelf(ctx);
        var cmd = display_mod.DrawCmd{ .tag = .move_display };
        cmd.display_id = if (argc >= 1) @intCast(@as(u32, @bitCast(getI(ctx, argv, 0))) & 3) else 0;
        cmd.f[0] = if (argc >= 2) getF(ctx, argv, 1) else 10;
        cmd.f[1] = if (argc >= 3) getF(ctx, argv, 2) else 10;
        self.pushGfx(cmd);
        return c.qjs_undefined();
    }

    fn jsGfxBegin(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        const self = getSelf(ctx);
        // Don't start new frames if interrupted
        if (self.c_interrupt_flag != 0) return c.qjs_undefined();
        var cmd = display_mod.DrawCmd{ .tag = .begin_frame };
        cmd.display_id = if (argc >= 1) @intCast(@as(u32, @bitCast(getI(ctx, argv, 0))) & 3) else 0;
        self.pushGfx(cmd);
        return c.qjs_undefined();
    }

    fn jsGfxEnd(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        const self = getSelf(ctx);
        var cmd = display_mod.DrawCmd{ .tag = .end_frame };
        cmd.display_id = if (argc >= 1) @intCast(@as(u32, @bitCast(getI(ctx, argv, 0))) & 3) else 0;
        self.pushGfx(cmd);
        return c.qjs_undefined();
    }

    fn jsGfxClear(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        const self = getSelf(ctx);
        const r: u8 = if (argc >= 1) @intCast(@as(u32, @bitCast(getI(ctx, argv, 0))) & 0xFF) else 0;
        const g: u8 = if (argc >= 2) @intCast(@as(u32, @bitCast(getI(ctx, argv, 1))) & 0xFF) else 0;
        const b: u8 = if (argc >= 3) @intCast(@as(u32, @bitCast(getI(ctx, argv, 2))) & 0xFF) else 0;
        self.pushGfx(.{ .tag = .clear, .color = .{ .r = r, .g = g, .b = b, .a = 255 } });
        return c.qjs_undefined();
    }

    fn jsGfxLine(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        if (argc < 5) return c.qjs_undefined();
        const self = getSelf(ctx);
        var cmd = display_mod.DrawCmd{ .tag = .line, .color = colorFromArgs(ctx, argv, 4) };
        cmd.f[0] = getF(ctx, argv, 0);
        cmd.f[1] = getF(ctx, argv, 1);
        cmd.f[2] = getF(ctx, argv, 2);
        cmd.f[3] = getF(ctx, argv, 3);
        cmd.f[4] = if (argc >= 6) getF(ctx, argv, 5) else 1.0;
        self.pushGfx(cmd);
        return c.qjs_undefined();
    }

    fn jsGfxRect(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        if (argc < 5) return c.qjs_undefined();
        const self = getSelf(ctx);
        var cmd = display_mod.DrawCmd{ .tag = .rect, .color = colorFromArgs(ctx, argv, 4) };
        cmd.f[0] = getF(ctx, argv, 0);
        cmd.f[1] = getF(ctx, argv, 1);
        cmd.f[2] = getF(ctx, argv, 2);
        cmd.f[3] = getF(ctx, argv, 3);
        self.pushGfx(cmd);
        return c.qjs_undefined();
    }

    fn jsGfxRectLines(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        if (argc < 5) return c.qjs_undefined();
        const self = getSelf(ctx);
        var cmd = display_mod.DrawCmd{ .tag = .rect_lines, .color = colorFromArgs(ctx, argv, 4) };
        cmd.f[0] = getF(ctx, argv, 0);
        cmd.f[1] = getF(ctx, argv, 1);
        cmd.f[2] = getF(ctx, argv, 2);
        cmd.f[3] = getF(ctx, argv, 3);
        cmd.f[4] = if (argc >= 6) getF(ctx, argv, 5) else 1.0;
        self.pushGfx(cmd);
        return c.qjs_undefined();
    }

    fn jsGfxCircle(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        if (argc < 4) return c.qjs_undefined();
        const self = getSelf(ctx);
        var cmd = display_mod.DrawCmd{ .tag = .circle, .color = colorFromArgs(ctx, argv, 3) };
        cmd.f[0] = getF(ctx, argv, 0);
        cmd.f[1] = getF(ctx, argv, 1);
        cmd.f[2] = getF(ctx, argv, 2);
        self.pushGfx(cmd);
        return c.qjs_undefined();
    }

    fn jsGfxTriangle(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        if (argc < 7) return c.qjs_undefined();
        const self = getSelf(ctx);
        var cmd = display_mod.DrawCmd{ .tag = .triangle, .color = colorFromArgs(ctx, argv, 6) };
        cmd.f[0] = getF(ctx, argv, 0);
        cmd.f[1] = getF(ctx, argv, 1);
        cmd.f[2] = getF(ctx, argv, 2);
        cmd.f[3] = getF(ctx, argv, 3);
        cmd.f[4] = getF(ctx, argv, 4);
        cmd.f[5] = getF(ctx, argv, 5);
        self.pushGfx(cmd);
        return c.qjs_undefined();
    }

    fn jsGfxText(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        if (argc < 3) return c.qjs_undefined();
        const self = getSelf(ctx);
        var cmd = display_mod.DrawCmd{ .tag = .text };
        cmd.f[0] = getF(ctx, argv, 0);
        cmd.f[1] = getF(ctx, argv, 1);
        const str = c.JS_ToCString(ctx, argv[2]);
        if (str != null) {
            const slice = cStrToSlice(str);
            const n = @min(slice.len, 64);
            @memcpy(cmd.text_buf[0..n], slice[0..n]);
            cmd.text_len = @intCast(n);
            c.JS_FreeCString(ctx, str);
        }
        cmd.f[2] = if (argc >= 4) getF(ctx, argv, 3) else 10;
        cmd.color = if (argc >= 5) colorFromArgs(ctx, argv, 4) else .{ .r = 255, .g = 255, .b = 255, .a = 255 };
        self.pushGfx(cmd);
        return c.qjs_undefined();
    }

    fn jsGfxCube(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        if (argc < 5) return c.qjs_undefined();
        const self = getSelf(ctx);
        var cmd = display_mod.DrawCmd{ .tag = .cube3d, .color = colorFromArgs(ctx, argv, 4) };
        cmd.f[0] = getF(ctx, argv, 0);
        cmd.f[1] = getF(ctx, argv, 1);
        cmd.f[2] = getF(ctx, argv, 2);
        cmd.f[3] = getF(ctx, argv, 3);
        cmd.f[4] = if (argc >= 6) getF(ctx, argv, 5) else 0;
        cmd.f[5] = if (argc >= 7) getF(ctx, argv, 6) else 0;
        self.pushGfx(cmd);
        return c.qjs_undefined();
    }

    fn jsGfxLine3d(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        if (argc < 7) return c.qjs_undefined();
        const self = getSelf(ctx);
        var cmd = display_mod.DrawCmd{ .tag = .line3d, .color = colorFromArgs(ctx, argv, 6) };
        cmd.f[0] = getF(ctx, argv, 0);
        cmd.f[1] = getF(ctx, argv, 1);
        cmd.f[2] = getF(ctx, argv, 2);
        cmd.f[3] = getF(ctx, argv, 3);
        cmd.f[4] = getF(ctx, argv, 4);
        cmd.f[5] = getF(ctx, argv, 5);
        self.pushGfx(cmd);
        return c.qjs_undefined();
    }

    fn jsGfxCamera(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        const self = getSelf(ctx);
        var cmd = display_mod.DrawCmd{ .tag = .set_camera };
        cmd.display_id = if (argc >= 1) @intCast(@as(u32, @bitCast(getI(ctx, argv, 0))) & 3) else 0;
        cmd.f[0] = if (argc >= 2) getF(ctx, argv, 1) else 5.0;
        cmd.f[1] = if (argc >= 3) getF(ctx, argv, 2) else 0.3;
        cmd.f[2] = if (argc >= 4) getF(ctx, argv, 3) else 0.0;
        self.pushGfx(cmd);
        return c.qjs_undefined();
    }

    /// gfx.begin3d(camX,camY,camZ, targetX,targetY,targetZ, fovy)
    fn jsGfxBegin3d(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        const self = getSelf(ctx);
        var cmd = display_mod.DrawCmd{ .tag = .begin3d };
        cmd.f[0] = if (argc >= 1) getF(ctx, argv, 0) else 5; // camX
        cmd.f[1] = if (argc >= 2) getF(ctx, argv, 1) else 5; // camY
        cmd.f[2] = if (argc >= 3) getF(ctx, argv, 2) else 5; // camZ
        cmd.f[3] = if (argc >= 4) getF(ctx, argv, 3) else 0; // targetX
        cmd.f[4] = if (argc >= 5) getF(ctx, argv, 4) else 0; // targetY
        cmd.f[5] = if (argc >= 6) getF(ctx, argv, 5) else 0; // targetZ
        cmd.f[6] = if (argc >= 7) getF(ctx, argv, 6) else 45; // fovy
        self.pushGfx(cmd);
        return c.qjs_undefined();
    }

    /// gfx.end3d()
    fn jsGfxEnd3d(ctx: ?*c.JSContext, _: c.JSValue, _: c_int, _: [*c]c.JSValue) callconv(.c) c.JSValue {
        const self = getSelf(ctx);
        self.pushGfx(.{ .tag = .end3d });
        return c.qjs_undefined();
    }

    /// gfx.triangle3d(x1,y1,z1, x2,y2,z2, x3,y3,z3, color)
    fn jsGfxTriangle3d(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        if (argc < 10) return c.qjs_undefined();
        const self = getSelf(ctx);
        var cmd = display_mod.DrawCmd{ .tag = .triangle3d, .color = colorFromArgs(ctx, argv, 9) };
        for (0..9) |i| {
            cmd.f[i] = getF(ctx, argv, i);
        }
        self.pushGfx(cmd);
        return c.qjs_undefined();
    }

    /// gfx.solidCube(x,y,z, size, color, rx, ry, lightX, lightY, lightZ)
    fn jsGfxSolidCube(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        if (argc < 5) return c.qjs_undefined();
        const self = getSelf(ctx);
        var cmd = display_mod.DrawCmd{ .tag = .cube3d_solid, .color = colorFromArgs(ctx, argv, 4) };
        cmd.f[0] = getF(ctx, argv, 0); // x
        cmd.f[1] = getF(ctx, argv, 1); // y
        cmd.f[2] = getF(ctx, argv, 2); // z
        cmd.f[3] = getF(ctx, argv, 3); // size
        cmd.f[4] = if (argc >= 6) getF(ctx, argv, 5) else 0; // rx
        cmd.f[5] = if (argc >= 7) getF(ctx, argv, 6) else 0; // ry
        cmd.f[6] = if (argc >= 8) getF(ctx, argv, 7) else 1; // lightX
        cmd.f[7] = if (argc >= 9) getF(ctx, argv, 8) else -1; // lightY
        cmd.f[8] = if (argc >= 10) getF(ctx, argv, 9) else 0.5; // lightZ
        self.pushGfx(cmd);
        return c.qjs_undefined();
    }

    fn jsGfxRgb(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        // Pack as: a | b<<8 | g<<16 | r<<24 — but avoid endian issues by using
        // a simple encoding: r in low byte, then g, b, a in high byte
        // Encode as r + g*256 + b*65536 + a*16777216 (little-endian friendly)
        var r: i32 = 255;
        var g: i32 = 255;
        var b: i32 = 255;
        if (argc >= 1) _ = c.JS_ToInt32(ctx, &r, argv[0]);
        if (argc >= 2) _ = c.JS_ToInt32(ctx, &g, argv[1]);
        if (argc >= 3) _ = c.JS_ToInt32(ctx, &b, argv[2]);
        // Encode as: r | g<<8 | b<<16 | 0xFF<<24
        const val: i64 = @as(i64, r & 0xFF) | (@as(i64, g & 0xFF) << 8) | (@as(i64, b & 0xFF) << 16) | (@as(i64, 0xFF) << 24);
        return c.JS_NewInt64(ctx, val);
    }

    fn jsGfxRgba(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        var r: i32 = 255;
        var g: i32 = 255;
        var b: i32 = 255;
        var a: i32 = 255;
        if (argc >= 1) _ = c.JS_ToInt32(ctx, &r, argv[0]);
        if (argc >= 2) _ = c.JS_ToInt32(ctx, &g, argv[1]);
        if (argc >= 3) _ = c.JS_ToInt32(ctx, &b, argv[2]);
        if (argc >= 4) _ = c.JS_ToInt32(ctx, &a, argv[3]);
        const val: i64 = @as(i64, r & 0xFF) | (@as(i64, g & 0xFF) << 8) | (@as(i64, b & 0xFF) << 16) | (@as(i64, a & 0xFF) << 24);
        return c.JS_NewInt64(ctx, val);
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
