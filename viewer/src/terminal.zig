const std = @import("std");
const rl = @import("rl.zig");
const parser_mod = @import("terminal_parser.zig");

// ---------------------------------------------------------------
// Cell — the fundamental unit of terminal state
// ---------------------------------------------------------------

pub const Attrs = packed struct(u16) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,
    _pad: u8 = 0,
};

pub const Cell = struct {
    char: u21 = ' ',
    fg: rl.Color = Terminal.DEFAULT_FG,
    bg: rl.Color = Terminal.DEFAULT_BG,
    attrs: Attrs = .{},
};

// ---------------------------------------------------------------
// Terminal
// ---------------------------------------------------------------

pub const Terminal = struct {
    pub const DEFAULT_FG = rl.Color{ .r = 200, .g = 200, .b = 200, .a = 255 };
    pub const DEFAULT_BG = rl.Color{ .r = 8, .g = 10, .b = 16, .a = 240 };
    pub const CURSOR_COLOR = rl.Color{ .r = 0, .g = 255, .b = 100, .a = 200 };
    const MAX_COLS: u16 = 320;
    const MAX_ROWS: u16 = 200;
    const SCROLLBACK_LINES: u32 = 5000;

    cols: u16 = 80,
    rows: u16 = 24,

    // Double-buffered cell grids
    cells_front: [MAX_ROWS * MAX_COLS]Cell = undefined,
    cells_back: [MAX_ROWS * MAX_COLS]Cell = undefined,

    // Per-row dirty flags (back buffer)
    dirty_rows: [MAX_ROWS]bool = .{false} ** MAX_ROWS,
    any_dirty: bool = true, // start dirty to force initial full draw
    full_dirty: bool = true,

    // Scrollback ring buffer
    scrollback: [SCROLLBACK_LINES * MAX_COLS]Cell = undefined,
    scrollback_head: u32 = 0,
    scrollback_count: u32 = 0,
    scroll_offset: u32 = 0, // how many lines user has scrolled up

    // Cursor
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,
    cursor_visible: bool = true,
    cursor_blink_timer: f32 = 0,
    cursor_blink_on: bool = true,
    saved_cursor_row: u16 = 0,
    saved_cursor_col: u16 = 0,

    // Scroll region
    scroll_top: u16 = 0,
    scroll_bottom: u16 = 23,

    // Current pen state
    current_fg: rl.Color = DEFAULT_FG,
    current_bg: rl.Color = DEFAULT_BG,
    current_attrs: Attrs = .{},

    // Alternate screen buffer
    alt_cells: [MAX_ROWS * MAX_COLS]Cell = undefined,
    alt_cursor_row: u16 = 0,
    alt_cursor_col: u16 = 0,
    using_alt: bool = false,

    // UTF-8 decoder state
    utf8_buf: [4]u8 = undefined,
    utf8_len: u8 = 0,
    utf8_expected: u8 = 0,

    // Parser
    parser: parser_mod.Parser = .{},

    // Rendering
    render_tex: rl.c.RenderTexture2D = undefined,
    font: rl.c.Font = undefined,
    cell_w: f32 = 0,
    cell_h: f32 = 0,
    font_size: f32 = 14,
    initialized: bool = false,

    // State
    visible: bool = false,
    focused: bool = false,

    // Input buffer (raw keypresses for external consumption)
    input_buf: [4096]u8 = undefined,
    input_len: u16 = 0,

    // Command line buffer (what the user is typing on the current line)
    cmd_buf: [1024]u8 = undefined,
    cmd_len: u16 = 0,
    cmd_ready: bool = false, // true when user pressed enter

    // Command callback
    prompt: []const u8 = "\x1b[1;32m>\x1b[0m ",

    // Raw key queue (for interactive programs like editors)
    raw_mode: bool = false,
    key_queue: [256]u8 = undefined,
    key_queue_len: u16 = 0,
    key_mutex: std.Thread.Mutex = .{},

    // ---------------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------------

    pub fn init(self: *Terminal, cols: u16, rows: u16, font_sz: f32) void {
        self.cols = @min(cols, MAX_COLS);
        self.rows = @min(rows, MAX_ROWS);
        self.font_size = font_sz;
        self.scroll_bottom = self.rows - 1;

        // Load a good Unicode monospace font
        // Codepoint range 0x20-0x25FF covers ASCII, Latin, box-drawing, block elements
        var codepoints: [9696]c_int = undefined;
        for (0..9696) |i| {
            codepoints[i] = @intCast(i + 0x20);
        }
        const font_paths = [_][*:0]const u8{
            "/usr/share/fonts/TTF/CascadiaMono.ttf",
            "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
            "/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
            "data/Px437_IBM_VGA_8x16.ttf",
            "viewer/data/Px437_IBM_VGA_8x16.ttf",
        };
        self.font = rl.c.GetFontDefault(); // fallback
        for (font_paths) |path| {
            const f = rl.c.LoadFontEx(path, @intFromFloat(font_sz), &codepoints, 9696);
            if (f.glyphCount > 0) {
                self.font = f;
                break;
            }
        }
        rl.c.SetTextureFilter(self.font.texture, rl.c.TEXTURE_FILTER_BILINEAR);

        // Measure cell dimensions
        const m = rl.c.MeasureTextEx(self.font, "M", font_sz, 0);
        self.cell_w = @ceil(m.x);
        self.cell_h = @ceil(font_sz * 1.2);

        const tex_w: c_int = @intFromFloat(self.cell_w * @as(f32, @floatFromInt(self.cols)));
        const tex_h: c_int = @intFromFloat(self.cell_h * @as(f32, @floatFromInt(self.rows)));
        self.render_tex = rl.c.LoadRenderTexture(tex_w, tex_h);
        rl.c.SetTextureFilter(self.render_tex.texture, rl.c.TEXTURE_FILTER_BILINEAR);

        // Clear both buffers
        self.clearGrid(&self.cells_front);
        self.clearGrid(&self.cells_back);
        self.clearGrid(&self.alt_cells);

        self.full_dirty = true;
        self.any_dirty = true;
        self.initialized = true;
    }

    pub fn deinit(self: *Terminal) void {
        if (!self.initialized) return;
        rl.c.UnloadRenderTexture(self.render_tex);
        self.initialized = false;
    }

    fn clearGrid(self: *const Terminal, grid: []Cell) void {
        const n = @as(usize, self.rows) * @as(usize, self.cols);
        for (grid[0..n]) |*cell| {
            cell.* = .{};
        }
    }

    // ---------------------------------------------------------------
    // Writing data (ANSI stream)
    // ---------------------------------------------------------------

    pub fn write(self: *Terminal, data: []const u8) void {
        for (data) |byte| {
            // UTF-8 decoding: accumulate multi-byte sequences
            if (self.utf8_expected > 0) {
                if (byte & 0xC0 == 0x80) {
                    // Continuation byte
                    self.utf8_buf[self.utf8_len] = byte;
                    self.utf8_len += 1;
                    if (self.utf8_len == self.utf8_expected) {
                        // Complete — decode codepoint
                        const cp = decodeUtf8(self.utf8_buf[0..self.utf8_len]);
                        self.utf8_expected = 0;
                        self.utf8_len = 0;
                        if (cp) |c| {
                            if (self.cursor_col >= self.cols) {
                                self.cursor_col = 0;
                                self.linefeed();
                            }
                            const idx = self.cellIdx(self.cursor_row, self.cursor_col);
                            var cell = &self.cells_back[idx];
                            cell.char = c;
                            cell.fg = self.current_fg;
                            cell.bg = self.current_bg;
                            cell.attrs = self.current_attrs;
                            self.markDirty(self.cursor_row);
                            self.cursor_col += 1;
                        }
                    }
                } else {
                    // Invalid sequence — discard and re-process this byte
                    self.utf8_expected = 0;
                    self.utf8_len = 0;
                    self.parser.feed(self, byte);
                }
            } else if (byte >= 0xC0 and byte < 0xF8) {
                // Start of multi-byte UTF-8 sequence
                self.utf8_buf[0] = byte;
                self.utf8_len = 1;
                if (byte < 0xE0) self.utf8_expected = 2
                else if (byte < 0xF0) self.utf8_expected = 3
                else self.utf8_expected = 4;
            } else {
                // ASCII or control — goes through the ANSI parser
                self.parser.feed(self, byte);
            }
        }
    }

    fn decodeUtf8(bytes: []const u8) ?u21 {
        if (bytes.len == 2) {
            return @as(u21, bytes[0] & 0x1F) << 6 | @as(u21, bytes[1] & 0x3F);
        } else if (bytes.len == 3) {
            return @as(u21, bytes[0] & 0x0F) << 12 | @as(u21, bytes[1] & 0x3F) << 6 | @as(u21, bytes[2] & 0x3F);
        } else if (bytes.len == 4) {
            return @as(u21, bytes[0] & 0x07) << 18 | @as(u21, bytes[1] & 0x3F) << 12 | @as(u21, bytes[2] & 0x3F) << 6 | @as(u21, bytes[3] & 0x3F);
        }
        return null;
    }

    /// Write a formatted string
    pub fn print(self: *Terminal, comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        const result = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.write(result);
    }

    // ---------------------------------------------------------------
    // Character output (called by parser)
    // ---------------------------------------------------------------

    pub fn putChar(self: *Terminal, ch: u21) void {
        if (self.cursor_col >= self.cols) {
            // Auto-wrap
            self.cursor_col = 0;
            self.linefeed();
        }
        const idx = self.cellIdx(self.cursor_row, self.cursor_col);
        var cell = &self.cells_back[idx];
        cell.char = ch;
        cell.fg = self.current_fg;
        cell.bg = self.current_bg;
        cell.attrs = self.current_attrs;
        self.markDirty(self.cursor_row);
        self.cursor_col += 1;
    }

    pub fn linefeed(self: *Terminal) void {
        if (self.cursor_row == self.scroll_bottom) {
            self.scrollUp(1);
        } else if (self.cursor_row < self.rows - 1) {
            self.cursor_row += 1;
        }
    }

    pub fn reverseIndex(self: *Terminal) void {
        if (self.cursor_row == self.scroll_top) {
            self.scrollDown(1);
        } else if (self.cursor_row > 0) {
            self.cursor_row -= 1;
        }
    }

    // ---------------------------------------------------------------
    // Cursor movement
    // ---------------------------------------------------------------

    pub fn moveCursorUp(self: *Terminal, n: u16) void {
        self.cursor_row -|= n;
        if (self.cursor_row < self.scroll_top) self.cursor_row = self.scroll_top;
    }

    pub fn moveCursorDown(self: *Terminal, n: u16) void {
        self.cursor_row = @min(self.cursor_row + n, self.scroll_bottom);
    }

    pub fn moveCursorForward(self: *Terminal, n: u16) void {
        self.cursor_col = @min(self.cursor_col + n, self.cols - 1);
    }

    pub fn moveCursorBack(self: *Terminal, n: u16) void {
        self.cursor_col -|= n;
    }

    pub fn saveCursor(self: *Terminal) void {
        self.saved_cursor_row = self.cursor_row;
        self.saved_cursor_col = self.cursor_col;
    }

    pub fn restoreCursor(self: *Terminal) void {
        self.cursor_row = @min(self.saved_cursor_row, self.rows - 1);
        self.cursor_col = @min(self.saved_cursor_col, self.cols - 1);
    }

    // ---------------------------------------------------------------
    // Erase operations
    // ---------------------------------------------------------------

    pub fn eraseDisplay(self: *Terminal, mode: u16) void {
        switch (mode) {
            0 => { // below
                self.eraseLineFrom(self.cursor_row, self.cursor_col);
                var r = self.cursor_row + 1;
                while (r < self.rows) : (r += 1) {
                    self.eraseRow(r);
                }
            },
            1 => { // above
                self.eraseLineTo(self.cursor_row, self.cursor_col);
                var r: u16 = 0;
                while (r < self.cursor_row) : (r += 1) {
                    self.eraseRow(r);
                }
            },
            2, 3 => { // all
                var r: u16 = 0;
                while (r < self.rows) : (r += 1) {
                    self.eraseRow(r);
                }
            },
            else => {},
        }
    }

    pub fn eraseLine(self: *Terminal, mode: u16) void {
        switch (mode) {
            0 => self.eraseLineFrom(self.cursor_row, self.cursor_col),
            1 => self.eraseLineTo(self.cursor_row, self.cursor_col),
            2 => self.eraseRow(self.cursor_row),
            else => {},
        }
    }

    pub fn eraseChars(self: *Terminal, n: u16) void {
        const end = @min(self.cursor_col + n, self.cols);
        var c = self.cursor_col;
        while (c < end) : (c += 1) {
            self.cells_back[self.cellIdx(self.cursor_row, c)] = .{};
        }
        self.markDirty(self.cursor_row);
    }

    fn eraseRow(self: *Terminal, row: u16) void {
        var c: u16 = 0;
        while (c < self.cols) : (c += 1) {
            self.cells_back[self.cellIdx(row, c)] = .{};
        }
        self.markDirty(row);
    }

    fn eraseLineFrom(self: *Terminal, row: u16, col: u16) void {
        var c = col;
        while (c < self.cols) : (c += 1) {
            self.cells_back[self.cellIdx(row, c)] = .{};
        }
        self.markDirty(row);
    }

    fn eraseLineTo(self: *Terminal, row: u16, col: u16) void {
        var c: u16 = 0;
        while (c <= col and c < self.cols) : (c += 1) {
            self.cells_back[self.cellIdx(row, c)] = .{};
        }
        self.markDirty(row);
    }

    // ---------------------------------------------------------------
    // Scroll operations
    // ---------------------------------------------------------------

    pub fn scrollUp(self: *Terminal, count: u16) void {
        var n = count;
        while (n > 0) : (n -= 1) {
            // Save top row to scrollback
            self.pushScrollback(self.scroll_top);

            // Shift rows up within scroll region
            var r = self.scroll_top;
            while (r < self.scroll_bottom) : (r += 1) {
                self.copyRow(r + 1, r);
                self.markDirty(r);
            }
            self.eraseRow(self.scroll_bottom);
        }
    }

    pub fn scrollDown(self: *Terminal, count: u16) void {
        var n = count;
        while (n > 0) : (n -= 1) {
            // Shift rows down within scroll region
            var r = self.scroll_bottom;
            while (r > self.scroll_top) : (r -= 1) {
                self.copyRow(r - 1, r);
                self.markDirty(r);
            }
            self.eraseRow(self.scroll_top);
        }
    }

    pub fn insertLines(self: *Terminal, count: u16) void {
        var n = count;
        while (n > 0) : (n -= 1) {
            var r = self.scroll_bottom;
            while (r > self.cursor_row) : (r -= 1) {
                self.copyRow(r - 1, r);
                self.markDirty(r);
            }
            self.eraseRow(self.cursor_row);
        }
    }

    pub fn deleteLines(self: *Terminal, count: u16) void {
        var n = count;
        while (n > 0) : (n -= 1) {
            var r = self.cursor_row;
            while (r < self.scroll_bottom) : (r += 1) {
                self.copyRow(r + 1, r);
                self.markDirty(r);
            }
            self.eraseRow(self.scroll_bottom);
        }
    }

    pub fn insertChars(self: *Terminal, count: u16) void {
        const row = self.cursor_row;
        var c = self.cols - 1;
        while (c >= self.cursor_col + count) : (c -= 1) {
            self.cells_back[self.cellIdx(row, c)] = self.cells_back[self.cellIdx(row, c - count)];
            if (c == 0) break;
        }
        var i: u16 = 0;
        while (i < count and self.cursor_col + i < self.cols) : (i += 1) {
            self.cells_back[self.cellIdx(row, self.cursor_col + i)] = .{};
        }
        self.markDirty(row);
    }

    pub fn deleteChars(self: *Terminal, count: u16) void {
        const row = self.cursor_row;
        var c = self.cursor_col;
        while (c + count < self.cols) : (c += 1) {
            self.cells_back[self.cellIdx(row, c)] = self.cells_back[self.cellIdx(row, c + count)];
        }
        while (c < self.cols) : (c += 1) {
            self.cells_back[self.cellIdx(row, c)] = .{};
        }
        self.markDirty(row);
    }

    // ---------------------------------------------------------------
    // Alternate screen
    // ---------------------------------------------------------------

    pub fn switchToAltScreen(self: *Terminal) void {
        if (self.using_alt) return;
        // Save main screen
        const n = @as(usize, self.rows) * @as(usize, self.cols);
        @memcpy(self.alt_cells[0..n], self.cells_back[0..n]);
        self.alt_cursor_row = self.cursor_row;
        self.alt_cursor_col = self.cursor_col;
        // Clear for alt
        self.clearGrid(&self.cells_back);
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.using_alt = true;
        self.full_dirty = true;
        self.any_dirty = true;
    }

    pub fn switchToMainScreen(self: *Terminal) void {
        if (!self.using_alt) return;
        // Restore main screen
        const n = @as(usize, self.rows) * @as(usize, self.cols);
        @memcpy(self.cells_back[0..n], self.alt_cells[0..n]);
        self.cursor_row = self.alt_cursor_row;
        self.cursor_col = self.alt_cursor_col;
        self.using_alt = false;
        self.full_dirty = true;
        self.any_dirty = true;
    }

    // ---------------------------------------------------------------
    // Attribute reset
    // ---------------------------------------------------------------

    pub fn resetAttrs(self: *Terminal) void {
        self.current_fg = DEFAULT_FG;
        self.current_bg = DEFAULT_BG;
        self.current_attrs = .{};
    }

    pub fn fullReset(self: *Terminal) void {
        self.resetAttrs();
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.cursor_visible = true;
        self.scroll_top = 0;
        self.scroll_bottom = self.rows - 1;
        self.clearGrid(&self.cells_back);
        self.full_dirty = true;
        self.any_dirty = true;
    }

    // ---------------------------------------------------------------
    // Input handling
    // ---------------------------------------------------------------

    pub fn handleInput(self: *Terminal) void {
        if (!self.focused) return;

        if (self.raw_mode) {
            self.handleRawInput();
            return;
        }

        // Read character input — echo and buffer for command line
        while (true) {
            const ch = rl.c.GetCharPressed();
            if (ch == 0) break;
            if (ch >= 32 and ch < 127) {
                if (self.cmd_len < self.cmd_buf.len) {
                    self.cmd_buf[self.cmd_len] = @intCast(ch);
                    self.cmd_len += 1;
                    // Echo the character
                    var echo: [1]u8 = .{@intCast(ch)};
                    self.write(&echo);
                }
            }
        }

        // Enter → submit command
        if (rl.isKeyPressed(rl.c.KEY_ENTER)) {
            self.write("\r\n");
            self.cmd_ready = true;
        }

        // Backspace
        if (rl.isKeyPressed(rl.c.KEY_BACKSPACE)) {
            if (self.cmd_len > 0) {
                self.cmd_len -= 1;
                self.write("\x08 \x08");
            }
        }

        // Mouse wheel → scrollback
        const wheel = rl.getMouseWheelMove();
        if (wheel > 0 and self.scroll_offset < self.scrollback_count) {
            self.scroll_offset += 3;
            if (self.scroll_offset > self.scrollback_count) self.scroll_offset = self.scrollback_count;
            self.full_dirty = true;
            self.any_dirty = true;
        }
        if (wheel < 0 and self.scroll_offset > 0) {
            if (self.scroll_offset >= 3) self.scroll_offset -= 3 else self.scroll_offset = 0;
            self.full_dirty = true;
            self.any_dirty = true;
        }
    }

    fn keyRepeat(key: c_int) bool {
        return rl.isKeyPressed(key) or rl.c.IsKeyPressedRepeat(key);
    }

    fn handleRawInput(self: *Terminal) void {
        self.key_mutex.lock();
        defer self.key_mutex.unlock();

        // Characters
        while (true) {
            const ch = rl.c.GetCharPressed();
            if (ch == 0) break;
            if (ch >= 32 and ch < 127) {
                self.pushKey(@intCast(ch));
            }
        }

        // Special keys — use IsKeyPressedRepeat for keys that should repeat
        if (keyRepeat(rl.c.KEY_ENTER)) self.pushKey(13);
        if (keyRepeat(rl.c.KEY_BACKSPACE)) self.pushKey(8);
        if (rl.isKeyPressed(rl.c.KEY_TAB)) self.pushKey(9);
        if (rl.isKeyPressed(rl.c.KEY_ESCAPE)) self.pushKey(27);
        if (keyRepeat(rl.c.KEY_DELETE)) self.pushKey(127);

        // Shift+Insert — paste (alternative shortcut)
        if (rl.c.IsKeyDown(rl.c.KEY_LEFT_SHIFT) or rl.c.IsKeyDown(rl.c.KEY_RIGHT_SHIFT)) {
            if (rl.isKeyPressed(rl.c.KEY_INSERT)) {
                self.pasteClipboard();
            }
        }

        // Arrow keys and nav — with repeat
        if (keyRepeat(rl.c.KEY_UP)) self.pushKeys("\x1b[A");
        if (keyRepeat(rl.c.KEY_DOWN)) self.pushKeys("\x1b[B");
        if (keyRepeat(rl.c.KEY_RIGHT)) self.pushKeys("\x1b[C");
        if (keyRepeat(rl.c.KEY_LEFT)) self.pushKeys("\x1b[D");
        if (keyRepeat(rl.c.KEY_HOME)) self.pushKeys("\x1b[H");
        if (keyRepeat(rl.c.KEY_END)) self.pushKeys("\x1b[F");
        if (keyRepeat(rl.c.KEY_PAGE_UP)) self.pushKeys("\x1b[5~");
        if (keyRepeat(rl.c.KEY_PAGE_DOWN)) self.pushKeys("\x1b[6~");

        // Ctrl combos
        if (rl.c.IsKeyDown(rl.c.KEY_LEFT_CONTROL) or rl.c.IsKeyDown(rl.c.KEY_RIGHT_CONTROL)) {
            if (rl.isKeyPressed(rl.c.KEY_S)) self.pushKey(19); // Ctrl-S
            if (rl.isKeyPressed(rl.c.KEY_Q)) self.pushKey(17); // Ctrl-Q
            if (rl.isKeyPressed(rl.c.KEY_X)) self.pushKey(24); // Ctrl-X
            if (rl.isKeyPressed(rl.c.KEY_O)) self.pushKey(15); // Ctrl-O
            if (rl.isKeyPressed(rl.c.KEY_K)) self.pushKey(11); // Ctrl-K
            if (rl.isKeyPressed(rl.c.KEY_G)) self.pushKey(7);  // Ctrl-G
            if (rl.isKeyPressed(rl.c.KEY_W)) self.pushKey(23); // Ctrl-W
            if (rl.isKeyPressed(rl.c.KEY_A)) self.pushKey(1);  // Ctrl-A (home)
            if (rl.isKeyPressed(rl.c.KEY_E)) self.pushKey(5);  // Ctrl-E (end)
            if (rl.isKeyPressed(rl.c.KEY_C)) self.pushKey(3);  // Ctrl-C
            if (rl.isKeyPressed(rl.c.KEY_D)) self.pushKey(4);  // Ctrl-D
            if (rl.isKeyPressed(rl.c.KEY_L)) self.pushKey(12); // Ctrl-L
            // Ctrl+Left/Right as CSI 1;5 D/C
            if (keyRepeat(rl.c.KEY_LEFT)) self.pushKeys("\x1b[1;5D");
            if (keyRepeat(rl.c.KEY_RIGHT)) self.pushKeys("\x1b[1;5C");
            // Ctrl+V or Ctrl+Shift+V — paste from clipboard
            if (rl.isKeyPressed(rl.c.KEY_V)) {
                self.pasteClipboard();
            }
        }
    }

    pub fn pushKey(self: *Terminal, key: u8) void {
        if (self.key_queue_len < self.key_queue.len) {
            self.key_queue[self.key_queue_len] = key;
            self.key_queue_len += 1;
        }
    }

    fn pushKeys(self: *Terminal, seq: []const u8) void {
        for (seq) |b| self.pushKey(b);
    }

    fn pasteClipboard(self: *Terminal) void {
        const clip = rl.c.GetClipboardText();
        if (clip == null) return;

        // Drain GetCharPressed — Raylib may also queue pasted chars there,
        // which would cause duplicates
        while (rl.c.GetCharPressed() != 0) {}

        var i: usize = 0;
        while (clip[i] != 0 and self.key_queue_len < self.key_queue.len) : (i += 1) {
            // Convert \n to \r for terminal (enter key)
            const ch = if (clip[i] == '\n') @as(u8, 13) else clip[i];
            self.pushKey(ch);
        }
    }

    /// Read one key from the queue (called from worker thread). Returns 0 if empty.
    pub fn readKey(self: *Terminal) u8 {
        self.key_mutex.lock();
        defer self.key_mutex.unlock();
        if (self.key_queue_len == 0) return 0;
        const key = self.key_queue[0];
        if (self.key_queue_len > 1) {
            std.mem.copyForwards(u8, self.key_queue[0 .. self.key_queue_len - 1], self.key_queue[1..self.key_queue_len]);
        }
        self.key_queue_len -= 1;
        return key;
    }

    /// Read an escape sequence from the queue. Returns slice of keys read.
    pub fn readKeySeq(self: *Terminal, buf: []u8) usize {
        const first = self.readKey();
        if (first == 0) return 0;
        buf[0] = first;
        if (first != 27) return 1; // not an escape sequence

        // Try to read the rest of the sequence
        var len: usize = 1;
        // Small sleep to let the sequence arrive
        std.time.sleep(5 * std.time.ns_per_ms);

        while (len < buf.len) {
            const next = self.readKey();
            if (next == 0) break;
            buf[len] = next;
            len += 1;
            // End of CSI sequence
            if (next >= 0x40 and next <= 0x7E and len >= 3) break;
        }
        return len;
    }

    /// Get the current command if one is ready (user pressed enter).
    /// Returns null if no command pending. Resets the command buffer and shows a new prompt.
    pub fn getCommand(self: *Terminal) ?[]const u8 {
        if (!self.cmd_ready) return null;
        self.cmd_ready = false;
        const cmd = self.cmd_buf[0..self.cmd_len];
        self.cmd_len = 0;
        return cmd;
    }

    /// Show the prompt
    pub fn showPrompt(self: *Terminal) void {
        self.write(self.prompt);
    }

    /// Read and consume pending input bytes
    pub fn readInput(self: *Terminal, buf: []u8) usize {
        const n = @min(self.input_len, @as(u16, @intCast(buf.len)));
        @memcpy(buf[0..n], self.input_buf[0..n]);
        // Shift remaining
        if (n < self.input_len) {
            const remaining = self.input_len - n;
            std.mem.copyForwards(u8, self.input_buf[0..remaining], self.input_buf[n..self.input_len]);
        }
        self.input_len -= n;
        return n;
    }

    fn pushInputSeq(self: *Terminal, seq: []const u8) void {
        for (seq) |b| {
            if (self.input_len < self.input_buf.len) {
                self.input_buf[self.input_len] = b;
                self.input_len += 1;
            }
        }
    }

    // ---------------------------------------------------------------
    // Update (per-frame)
    // ---------------------------------------------------------------

    pub fn update(self: *Terminal, dt: f32) void {
        // Cursor blink
        self.cursor_blink_timer += dt;
        if (self.cursor_blink_timer >= 0.5) {
            self.cursor_blink_timer -= 0.5;
            self.cursor_blink_on = !self.cursor_blink_on;
        }
    }

    // ---------------------------------------------------------------
    // Swap (double-buffer)
    // ---------------------------------------------------------------

    pub fn swap(self: *Terminal) void {
        if (!self.any_dirty) return;

        const n = @as(usize, self.cols);

        if (self.full_dirty) {
            // Full copy
            const total = @as(usize, self.rows) * n;
            @memcpy(self.cells_front[0..total], self.cells_back[0..total]);
        } else {
            // Copy only dirty rows
            for (0..self.rows) |r| {
                if (self.dirty_rows[r]) {
                    const start = r * n;
                    const end = start + n;
                    @memcpy(self.cells_front[start..end], self.cells_back[start..end]);
                }
            }
        }

        self.dirty_rows = .{false} ** MAX_ROWS;
        self.full_dirty = false;
        self.any_dirty = false;
    }

    // ---------------------------------------------------------------
    // Rendering
    // ---------------------------------------------------------------

    pub fn render(self: *Terminal) void {
        if (!self.initialized) return;

        self.swap();

        const cw = self.cell_w;
        const ch = self.cell_h;

        rl.c.BeginTextureMode(self.render_tex);

        // Full clear on first render or after scroll
        rl.c.ClearBackground(rl.c.Color{ .r = DEFAULT_BG.r, .g = DEFAULT_BG.g, .b = DEFAULT_BG.b, .a = DEFAULT_BG.a });

        // Draw cells
        for (0..self.rows) |r| {
            for (0..self.cols) |c_idx| {
                const cell = self.cells_front[r * @as(usize, self.cols) + c_idx];
                const x: f32 = @as(f32, @floatFromInt(c_idx)) * cw;
                const y: f32 = @as(f32, @floatFromInt(r)) * ch;

                // Resolve colors (handle reverse attribute)
                var fg = cell.fg;
                var bg = cell.bg;
                if (cell.attrs.reverse) {
                    const tmp = fg;
                    fg = bg;
                    bg = tmp;
                }

                // Bold brightens foreground
                if (cell.attrs.bold) {
                    fg.r = @min(@as(u16, fg.r) + 55, 255);
                    fg.g = @min(@as(u16, fg.g) + 55, 255);
                    fg.b = @min(@as(u16, fg.b) + 55, 255);
                }

                // Dim reduces foreground
                if (cell.attrs.dim) {
                    fg.r /= 2;
                    fg.g /= 2;
                    fg.b /= 2;
                }

                // Background (skip if default to avoid overdraw)
                if (bg.r != DEFAULT_BG.r or bg.g != DEFAULT_BG.g or bg.b != DEFAULT_BG.b) {
                    rl.c.DrawRectangleV(
                        rl.c.Vector2{ .x = x, .y = y },
                        rl.c.Vector2{ .x = cw, .y = ch },
                        bg,
                    );
                }

                // Character
                if (cell.char > 32) {
                    rl.c.DrawTextCodepoint(self.font, @intCast(cell.char), rl.c.Vector2{ .x = x, .y = y + 1 }, self.font_size, fg);

                    // Glow effect for bold text
                    if (cell.attrs.bold) {
                        const glow_col = rl.c.Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 40 };
                        rl.c.DrawTextCodepoint(self.font, @intCast(cell.char), rl.c.Vector2{ .x = x + 0.5, .y = y + 0.5 }, self.font_size + 1, glow_col);
                    }
                }

                // Underline
                if (cell.attrs.underline) {
                    rl.c.DrawLineV(
                        rl.c.Vector2{ .x = x, .y = y + ch - 1 },
                        rl.c.Vector2{ .x = x + cw, .y = y + ch - 1 },
                        fg,
                    );
                }

                // Strikethrough
                if (cell.attrs.strikethrough) {
                    rl.c.DrawLineV(
                        rl.c.Vector2{ .x = x, .y = y + ch * 0.5 },
                        rl.c.Vector2{ .x = x + cw, .y = y + ch * 0.5 },
                        fg,
                    );
                }
            }
        }

        // Cursor
        if (self.cursor_visible and self.cursor_blink_on and self.scroll_offset == 0) {
            const cx: f32 = @as(f32, @floatFromInt(self.cursor_col)) * cw;
            const cy: f32 = @as(f32, @floatFromInt(self.cursor_row)) * ch;
            rl.c.DrawRectangleV(
                rl.c.Vector2{ .x = cx, .y = cy },
                rl.c.Vector2{ .x = cw, .y = ch },
                CURSOR_COLOR,
            );
            // Redraw character on top of cursor for visibility
            const cursor_cell = self.cells_front[self.cellIdx(self.cursor_row, self.cursor_col)];
            if (cursor_cell.char > 32) {
                rl.c.DrawTextCodepoint(self.font, @intCast(cursor_cell.char), rl.c.Vector2{ .x = cx, .y = cy + 1 }, self.font_size, DEFAULT_BG);
            }
        }

        rl.c.EndTextureMode();
    }

    /// Blit the terminal render texture to screen at position (x, y)
    pub fn draw(self: *const Terminal, x: f32, y: f32) void {
        if (!self.initialized) return;
        const tex = self.render_tex.texture;
        const w: f32 = @floatFromInt(tex.width);
        const h: f32 = @floatFromInt(tex.height);
        // Y-flip for OpenGL render textures
        const src = rl.c.Rectangle{ .x = 0, .y = 0, .width = w, .height = -h };
        const dst = rl.c.Rectangle{ .x = x, .y = y, .width = w, .height = h };
        rl.c.DrawTexturePro(tex, src, dst, rl.c.Vector2{ .x = 0, .y = 0 }, 0, rl.c.WHITE);
    }

    /// Blit scaled to fit a given rectangle
    pub fn drawScaled(self: *const Terminal, x: f32, y: f32, w: f32, h: f32) void {
        if (!self.initialized) return;
        const tex = self.render_tex.texture;
        const tw: f32 = @floatFromInt(tex.width);
        const th: f32 = @floatFromInt(tex.height);
        const src = rl.c.Rectangle{ .x = 0, .y = 0, .width = tw, .height = -th };
        const dst = rl.c.Rectangle{ .x = x, .y = y, .width = w, .height = h };
        rl.c.DrawTexturePro(tex, src, dst, rl.c.Vector2{ .x = 0, .y = 0 }, 0, rl.c.WHITE);
    }

    // ---------------------------------------------------------------
    // Scrollback
    // ---------------------------------------------------------------

    fn pushScrollback(self: *Terminal, row: u16) void {
        const dst_start = @as(usize, self.scrollback_head) * @as(usize, MAX_COLS);
        const src_start = @as(usize, row) * @as(usize, self.cols);
        @memcpy(
            self.scrollback[dst_start..][0..self.cols],
            self.cells_back[src_start..][0..self.cols],
        );
        self.scrollback_head = (self.scrollback_head + 1) % SCROLLBACK_LINES;
        if (self.scrollback_count < SCROLLBACK_LINES) self.scrollback_count += 1;
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    fn cellIdx(self: *const Terminal, row: u16, col: u16) usize {
        return @as(usize, row) * @as(usize, self.cols) + @as(usize, col);
    }

    fn copyRow(self: *Terminal, src: u16, dst: u16) void {
        const n = @as(usize, self.cols);
        const s = @as(usize, src) * n;
        const d = @as(usize, dst) * n;
        if (src < dst) {
            std.mem.copyBackwards(Cell, self.cells_back[d..][0..n], self.cells_back[s..][0..n]);
        } else {
            std.mem.copyForwards(Cell, self.cells_back[d..][0..n], self.cells_back[s..][0..n]);
        }
    }

    pub fn markDirty(self: *Terminal, row: u16) void {
        self.dirty_rows[row] = true;
        self.any_dirty = true;
    }
};
