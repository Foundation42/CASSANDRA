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
    char: u8 = ' ',
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

    // Input buffer (what the user has typed)
    input_buf: [4096]u8 = undefined,
    input_len: u16 = 0,

    // ---------------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------------

    pub fn init(self: *Terminal, cols: u16, rows: u16, font_sz: f32) void {
        self.cols = @min(cols, MAX_COLS);
        self.rows = @min(rows, MAX_ROWS);
        self.font_size = font_sz;
        self.scroll_bottom = self.rows - 1;

        // Load a monospace font — try system, fall back to default
        self.font = rl.c.LoadFontEx("viewer/data/terminal_font.ttf", @intFromFloat(font_sz * 2), null, 0);
        if (self.font.glyphCount == 0) {
            self.font = rl.c.GetFontDefault();
        }

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
            self.parser.feed(self, byte);
        }
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

    pub fn putChar(self: *Terminal, ch: u8) void {
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

        // Read character input
        while (true) {
            const ch = rl.c.GetCharPressed();
            if (ch == 0) break;
            if (ch >= 32 and ch < 127 and self.input_len < self.input_buf.len) {
                self.input_buf[self.input_len] = @intCast(ch);
                self.input_len += 1;
            }
        }

        // Special keys
        if (rl.isKeyPressed(rl.c.KEY_ENTER)) {
            if (self.input_len < self.input_buf.len) {
                self.input_buf[self.input_len] = '\n';
                self.input_len += 1;
            }
        }
        if (rl.isKeyPressed(rl.c.KEY_BACKSPACE)) {
            if (self.input_len < self.input_buf.len) {
                self.input_buf[self.input_len] = 0x08;
                self.input_len += 1;
            }
        }

        // Arrow keys → ANSI escape sequences
        if (rl.isKeyPressed(rl.c.KEY_UP)) self.pushInputSeq("\x1b[A");
        if (rl.isKeyPressed(rl.c.KEY_DOWN)) self.pushInputSeq("\x1b[B");
        if (rl.isKeyPressed(rl.c.KEY_RIGHT)) self.pushInputSeq("\x1b[C");
        if (rl.isKeyPressed(rl.c.KEY_LEFT)) self.pushInputSeq("\x1b[D");
        if (rl.isKeyPressed(rl.c.KEY_HOME)) self.pushInputSeq("\x1b[H");
        if (rl.isKeyPressed(rl.c.KEY_END)) self.pushInputSeq("\x1b[F");
        if (rl.isKeyPressed(rl.c.KEY_DELETE)) self.pushInputSeq("\x1b[3~");
        if (rl.isKeyPressed(rl.c.KEY_TAB)) {
            if (self.input_len < self.input_buf.len) {
                self.input_buf[self.input_len] = '\t';
                self.input_len += 1;
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

    fn markDirty(self: *Terminal, row: u16) void {
        self.dirty_rows[row] = true;
        self.any_dirty = true;
    }
};
