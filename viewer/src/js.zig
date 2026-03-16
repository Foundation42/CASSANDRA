const std = @import("std");
const terminal_mod = @import("terminal.zig");

pub const c = @cImport({
    @cInclude("quickjs.h");
    @cInclude("quickjs-zig-helpers.h");
});

/// JavaScript runtime powered by QuickJS, wired to the CASSANDRA terminal.
pub const JsRuntime = struct {
    rt: *c.JSRuntime,
    ctx: *c.JSContext,
    term: *terminal_mod.Terminal,

    pub fn init(term: *terminal_mod.Terminal) ?JsRuntime {
        const rt = c.JS_NewRuntime() orelse return null;
        const ctx = c.JS_NewContext(rt) orelse {
            c.JS_FreeRuntime(rt);
            return null;
        };

        var self = JsRuntime{
            .rt = rt,
            .ctx = ctx,
            .term = term,
        };

        self.registerBuiltins();
        return self;
    }

    pub fn deinit(self: *JsRuntime) void {
        c.JS_FreeContext(self.ctx);
        c.JS_FreeRuntime(self.rt);
    }

    /// Execute a JavaScript string. Errors are printed to the terminal.
    pub fn eval(self: *JsRuntime, code: []const u8, filename: []const u8) void {
        // Need null-terminated strings for QuickJS
        var code_z: [32768]u8 = undefined;
        const code_len = @min(code.len, code_z.len - 1);
        @memcpy(code_z[0..code_len], code[0..code_len]);
        code_z[code_len] = 0;

        var file_z: [256]u8 = undefined;
        const file_len = @min(filename.len, file_z.len - 1);
        @memcpy(file_z[0..file_len], filename[0..file_len]);
        file_z[file_len] = 0;

        const val = c.JS_Eval(self.ctx, &code_z, code_len, &file_z, c.JS_EVAL_TYPE_GLOBAL);
        defer c.JS_FreeValue(self.ctx, val);

        if (c.qjs_is_exception(val) != 0) {
            self.printException();
            return;
        }

        // If the result is not undefined, print it
        if (c.qjs_is_undefined(val) == 0) {
            const str = c.JS_ToCString(self.ctx, val);
            if (str != null) {
                self.term.write("\x1b[0;37m");
                var i: usize = 0;
                while (str[i] != 0) : (i += 1) {}
                self.term.write(str[0..i]);
                self.term.write("\x1b[0m\r\n");
                c.JS_FreeCString(self.ctx, str);
            }
        }
    }

    /// Execute a JavaScript file from disk.
    pub fn evalFile(self: *JsRuntime, path: []const u8) void {
        const file = std.fs.cwd().openFile(path, .{}) catch {
            self.term.print("\x1b[1;31mError:\x1b[0m could not open {s}\r\n", .{path});
            return;
        };
        defer file.close();

        var buf: [32768]u8 = undefined;
        const n = file.readAll(&buf) catch {
            self.term.print("\x1b[1;31mError:\x1b[0m could not read {s}\r\n", .{path});
            return;
        };

        self.eval(buf[0..n], path);
    }

    fn printException(self: *JsRuntime) void {
        const ex = c.JS_GetException(self.ctx);
        defer c.JS_FreeValue(self.ctx, ex);

        const str = c.JS_ToCString(self.ctx, ex);
        if (str != null) {
            self.term.write("\x1b[1;31m");
            var i: usize = 0;
            while (str[i] != 0) : (i += 1) {}
            self.term.write(str[0..i]);
            self.term.write("\x1b[0m\r\n");
            c.JS_FreeCString(self.ctx, str);
        }

        // Print stack trace if available
        if (c.qjs_is_object(ex) != 0) {
            const stack = c.JS_GetPropertyStr(self.ctx, ex, "stack");
            defer c.JS_FreeValue(self.ctx, stack);
            if (c.qjs_is_undefined(stack) == 0) {
                const stack_str = c.JS_ToCString(self.ctx, stack);
                if (stack_str != null) {
                    self.term.write("\x1b[0;31m");
                    var j: usize = 0;
                    while (stack_str[j] != 0) : (j += 1) {}
                    self.term.write(stack_str[0..j]);
                    self.term.write("\x1b[0m\r\n");
                    c.JS_FreeCString(self.ctx, stack_str);
                }
            }
        }
    }

    // ---------------------------------------------------------------
    // Built-in JavaScript functions
    // ---------------------------------------------------------------

    fn registerBuiltins(self: *JsRuntime) void {
        const global = c.JS_GetGlobalObject(self.ctx);
        defer c.JS_FreeValue(self.ctx, global);

        // Store terminal pointer in context opaque
        c.JS_SetContextOpaque(self.ctx, @ptrCast(self.term));

        // print(...args) — output to terminal
        _ = c.JS_SetPropertyStr(self.ctx, global, "print", c.JS_NewCFunction(self.ctx, jsPrint, "print", 1));

        // clear() — clear terminal
        _ = c.JS_SetPropertyStr(self.ctx, global, "clear", c.JS_NewCFunction(self.ctx, jsClear, "clear", 0));

        // sleep(ms) — sleep (blocking, use sparingly)
        _ = c.JS_SetPropertyStr(self.ctx, global, "sleep", c.JS_NewCFunction(self.ctx, jsSleep, "sleep", 1));

        // Create 'term' object with color helpers
        const term_obj = c.JS_NewObject(self.ctx);
        _ = c.JS_SetPropertyStr(self.ctx, term_obj, "write", c.JS_NewCFunction(self.ctx, jsTermWrite, "write", 1));
        _ = c.JS_SetPropertyStr(self.ctx, term_obj, "cursor", c.JS_NewCFunction(self.ctx, jsTermCursor, "cursor", 2));
        _ = c.JS_SetPropertyStr(self.ctx, term_obj, "color", c.JS_NewCFunction(self.ctx, jsTermColor, "color", 1));
        _ = c.JS_SetPropertyStr(self.ctx, term_obj, "reset", c.JS_NewCFunction(self.ctx, jsTermReset, "reset", 0));
        _ = c.JS_SetPropertyStr(self.ctx, term_obj, "cols", c.JS_NewInt32(self.ctx, @intCast(self.term.cols)));
        _ = c.JS_SetPropertyStr(self.ctx, term_obj, "rows", c.JS_NewInt32(self.ctx, @intCast(self.term.rows)));
        _ = c.JS_SetPropertyStr(self.ctx, global, "term", term_obj);

        // Create 'fs' object — filesystem access
        const fs_obj = c.JS_NewObject(self.ctx);
        _ = c.JS_SetPropertyStr(self.ctx, fs_obj, "readFile", c.JS_NewCFunction(self.ctx, jsFsReadFile, "readFile", 1));
        _ = c.JS_SetPropertyStr(self.ctx, fs_obj, "writeFile", c.JS_NewCFunction(self.ctx, jsFsWriteFile, "writeFile", 2));
        _ = c.JS_SetPropertyStr(self.ctx, fs_obj, "listDir", c.JS_NewCFunction(self.ctx, jsFsListDir, "listDir", 1));
        _ = c.JS_SetPropertyStr(self.ctx, fs_obj, "exists", c.JS_NewCFunction(self.ctx, jsFsExists, "exists", 1));
        _ = c.JS_SetPropertyStr(self.ctx, global, "fs", fs_obj);
    }

    // ---------------------------------------------------------------
    // JS C function implementations
    // ---------------------------------------------------------------

    fn getTerm(ctx: ?*c.JSContext) *terminal_mod.Terminal {
        const ptr = c.JS_GetContextOpaque(ctx);
        return @ptrCast(@alignCast(ptr));
    }

    fn jsPrint(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        const term = getTerm(ctx);
        var i: c_int = 0;
        while (i < argc) : (i += 1) {
            if (i > 0) term.write(" ");
            const str = c.JS_ToCString(ctx, argv[@intCast(i)]);
            if (str != null) {
                var len: usize = 0;
                while (str[len] != 0) : (len += 1) {}
                term.write(str[0..len]);
                c.JS_FreeCString(ctx, str);
            }
        }
        term.write("\r\n");
        return c.qjs_undefined();
    }

    fn jsClear(ctx: ?*c.JSContext, _: c.JSValue, _: c_int, _: [*c]c.JSValue) callconv(.c) c.JSValue {
        const term = getTerm(ctx);
        term.write("\x1b[2J\x1b[H");
        return c.qjs_undefined();
    }

    fn jsSleep(_: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        if (argc >= 1) {
            var ms: i32 = 0;
            _ = c.JS_ToInt32(null, &ms, argv[0]);
            if (ms > 0 and ms < 10000) {
                std.time.sleep(@as(u64, @intCast(ms)) * std.time.ns_per_ms);
            }
        }
        return c.qjs_undefined();
    }

    fn jsTermWrite(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        const term = getTerm(ctx);
        if (argc >= 1) {
            const str = c.JS_ToCString(ctx, argv[0]);
            if (str != null) {
                var len: usize = 0;
                while (str[len] != 0) : (len += 1) {}
                term.write(str[0..len]);
                c.JS_FreeCString(ctx, str);
            }
        }
        return c.qjs_undefined();
    }

    fn jsTermCursor(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        const term = getTerm(ctx);
        if (argc >= 2) {
            var row: i32 = 0;
            var col: i32 = 0;
            _ = c.JS_ToInt32(ctx, &row, argv[0]);
            _ = c.JS_ToInt32(ctx, &col, argv[1]);
            term.print("\x1b[{d};{d}H", .{ row, col });
        }
        return c.qjs_undefined();
    }

    fn jsTermColor(ctx: ?*c.JSContext, _: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
        const term = getTerm(ctx);
        if (argc >= 1) {
            const str = c.JS_ToCString(ctx, argv[0]);
            if (str != null) {
                // Accept color names or raw ANSI codes
                var len: usize = 0;
                while (str[len] != 0) : (len += 1) {}
                const color = str[0..len];
                if (std.mem.eql(u8, color, "red")) {
                    term.write("\x1b[1;31m");
                } else if (std.mem.eql(u8, color, "green")) {
                    term.write("\x1b[1;32m");
                } else if (std.mem.eql(u8, color, "yellow")) {
                    term.write("\x1b[1;33m");
                } else if (std.mem.eql(u8, color, "blue")) {
                    term.write("\x1b[1;34m");
                } else if (std.mem.eql(u8, color, "magenta")) {
                    term.write("\x1b[1;35m");
                } else if (std.mem.eql(u8, color, "cyan")) {
                    term.write("\x1b[1;36m");
                } else if (std.mem.eql(u8, color, "white")) {
                    term.write("\x1b[1;37m");
                } else {
                    // Raw ANSI: term.color("38;5;196")
                    term.write("\x1b[");
                    term.write(color);
                    term.write("m");
                }
                c.JS_FreeCString(ctx, str);
            }
        }
        return c.qjs_undefined();
    }

    fn jsTermReset(ctx: ?*c.JSContext, _: c.JSValue, _: c_int, _: [*c]c.JSValue) callconv(.c) c.JSValue {
        const term = getTerm(ctx);
        term.write("\x1b[0m");
        return c.qjs_undefined();
    }

    // ---------------------------------------------------------------
    // Filesystem functions
    // ---------------------------------------------------------------

    fn cStrToSlice(cstr: [*c]const u8) []const u8 {
        var len: usize = 0;
        while (cstr[len] != 0) : (len += 1) {}
        return cstr[0..len];
    }

    /// fs.readFile(path) -> string | null
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

    /// fs.writeFile(path, content) -> bool
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

    /// fs.listDir(path) -> [string] | null
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
            if (idx >= 1000) break; // safety limit
        }

        return arr;
    }

    /// fs.exists(path) -> bool
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
