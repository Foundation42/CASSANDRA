const std = @import("std");
const Terminal = @import("terminal.zig").Terminal;
const rl_import = @import("rl.zig");

// ---------------------------------------------------------------
// xterm-256 color palette
// ---------------------------------------------------------------

pub const palette_256: [256]rl_import.Color = blk: {
    var pal: [256]rl_import.Color = undefined;

    // 0-7: standard colors
    pal[0] = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pal[1] = .{ .r = 170, .g = 0, .b = 0, .a = 255 };
    pal[2] = .{ .r = 0, .g = 170, .b = 0, .a = 255 };
    pal[3] = .{ .r = 170, .g = 85, .b = 0, .a = 255 };
    pal[4] = .{ .r = 0, .g = 0, .b = 170, .a = 255 };
    pal[5] = .{ .r = 170, .g = 0, .b = 170, .a = 255 };
    pal[6] = .{ .r = 0, .g = 170, .b = 170, .a = 255 };
    pal[7] = .{ .r = 170, .g = 170, .b = 170, .a = 255 };

    // 8-15: bright colors
    pal[8] = .{ .r = 85, .g = 85, .b = 85, .a = 255 };
    pal[9] = .{ .r = 255, .g = 85, .b = 85, .a = 255 };
    pal[10] = .{ .r = 85, .g = 255, .b = 85, .a = 255 };
    pal[11] = .{ .r = 255, .g = 255, .b = 85, .a = 255 };
    pal[12] = .{ .r = 85, .g = 85, .b = 255, .a = 255 };
    pal[13] = .{ .r = 255, .g = 85, .b = 255, .a = 255 };
    pal[14] = .{ .r = 85, .g = 255, .b = 255, .a = 255 };
    pal[15] = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

    // 16-231: 6x6x6 color cube
    for (0..216) |i| {
        const idx = i + 16;
        const b_val: u8 = @intCast(i % 6);
        const g_val: u8 = @intCast((i / 6) % 6);
        const r_val: u8 = @intCast(i / 36);
        pal[idx] = .{
            .r = if (r_val == 0) 0 else @as(u8, 55) + r_val * 40,
            .g = if (g_val == 0) 0 else @as(u8, 55) + g_val * 40,
            .b = if (b_val == 0) 0 else @as(u8, 55) + b_val * 40,
            .a = 255,
        };
    }

    // 232-255: grayscale ramp
    for (0..24) |i| {
        const idx = i + 232;
        const v: u8 = @intCast(8 + i * 10);
        pal[idx] = .{ .r = v, .g = v, .b = v, .a = 255 };
    }

    break :blk pal;
};

// Standard 8+8 color lookup for SGR 30-37, 40-47, 90-97, 100-107
pub fn standardColor(code: u16) rl_import.Color {
    if (code < 256) return palette_256[code];
    return palette_256[7]; // fallback white
}

// ---------------------------------------------------------------
// ANSI Parser State Machine
// ---------------------------------------------------------------

pub const ParserState = enum {
    ground,
    escape,
    csi_entry,
    csi_param,
    csi_intermediate,
    osc_string,
    osc_escape, // saw ESC inside OSC, expecting '\'
};

const MAX_PARAMS: usize = 16;

pub const Parser = struct {
    state: ParserState = .ground,
    params: [MAX_PARAMS]u16 = .{0} ** MAX_PARAMS,
    param_count: u8 = 0,
    private_marker: u8 = 0, // '?' for DEC private modes
    intermediate: u8 = 0,

    pub fn feed(self: *Parser, term: *Terminal, byte: u8) void {
        switch (self.state) {
            .ground => self.handleGround(term, byte),
            .escape => self.handleEscape(term, byte),
            .csi_entry => self.handleCsiEntry(term, byte),
            .csi_param => self.handleCsiParam(term, byte),
            .csi_intermediate => self.handleCsiIntermediate(term, byte),
            .osc_string => self.handleOsc(byte),
            .osc_escape => {
                // ESC \ terminates OSC
                self.state = .ground;
            },
        }
    }

    fn reset(self: *Parser) void {
        self.params = .{0} ** MAX_PARAMS;
        self.param_count = 0;
        self.private_marker = 0;
        self.intermediate = 0;
    }

    fn handleGround(self: *Parser, term: *Terminal, byte: u8) void {
        switch (byte) {
            0x1B => { // ESC
                self.reset();
                self.state = .escape;
            },
            '\n' => {
                term.cursor_col = 0; // implicit CR on LF (Unix convention)
                term.linefeed();
            },
            '\r' => {
                term.cursor_col = 0;
            },
            '\t' => {
                // Tab to next 8-column stop
                const next = (term.cursor_col + 8) & ~@as(u16, 7);
                term.cursor_col = @min(next, term.cols - 1);
            },
            0x08 => { // Backspace
                if (term.cursor_col > 0) term.cursor_col -= 1;
            },
            0x07 => {}, // BEL — ignore
            0x00...0x06, 0x0E...0x1A, 0x1C...0x1F => {}, // other C0 — ignore
            else => {
                // Printable character
                term.putChar(byte);
            },
        }
    }

    fn handleEscape(self: *Parser, term: *Terminal, byte: u8) void {
        switch (byte) {
            '[' => {
                self.state = .csi_entry;
            },
            ']' => {
                self.state = .osc_string;
            },
            'c' => {
                // RIS — full reset
                term.fullReset();
                self.state = .ground;
            },
            'D' => { // IND — index (linefeed)
                term.linefeed();
                self.state = .ground;
            },
            'E' => { // NEL — next line
                term.cursor_col = 0;
                term.linefeed();
                self.state = .ground;
            },
            'M' => { // RI — reverse index
                term.reverseIndex();
                self.state = .ground;
            },
            '7' => { // DECSC — save cursor
                term.saveCursor();
                self.state = .ground;
            },
            '8' => { // DECRC — restore cursor
                term.restoreCursor();
                self.state = .ground;
            },
            else => {
                self.state = .ground; // unrecognized, back to ground
            },
        }
    }

    fn handleCsiEntry(self: *Parser, term: *Terminal, byte: u8) void {
        switch (byte) {
            '?' => {
                self.private_marker = '?';
                self.state = .csi_param;
            },
            '>' => {
                self.private_marker = '>';
                self.state = .csi_param;
            },
            '0'...'9' => {
                self.params[0] = byte - '0';
                self.param_count = 1;
                self.state = .csi_param;
            },
            ';' => {
                self.param_count = 2; // first param is implicit 0
                self.state = .csi_param;
            },
            0x20...0x2F => { // intermediate bytes
                self.intermediate = byte;
                self.state = .csi_intermediate;
            },
            0x40...0x7E => { // dispatch immediately (no params)
                self.param_count = 0;
                dispatchCsi(self, term, byte);
                self.state = .ground;
            },
            else => {
                self.state = .ground;
            },
        }
    }

    fn handleCsiParam(self: *Parser, term: *Terminal, byte: u8) void {
        switch (byte) {
            '0'...'9' => {
                if (self.param_count == 0) self.param_count = 1;
                const idx = self.param_count - 1;
                if (idx < MAX_PARAMS) {
                    self.params[idx] = self.params[idx] *% 10 +% (byte - '0');
                }
            },
            ';' => {
                if (self.param_count < MAX_PARAMS) {
                    self.param_count += 1;
                }
            },
            0x20...0x2F => {
                self.intermediate = byte;
                self.state = .csi_intermediate;
            },
            0x40...0x7E => {
                dispatchCsi(self, term, byte);
                self.state = .ground;
            },
            else => {
                self.state = .ground;
            },
        }
    }

    fn handleCsiIntermediate(self: *Parser, term: *Terminal, byte: u8) void {
        switch (byte) {
            0x20...0x2F => {
                self.intermediate = byte;
            },
            0x40...0x7E => {
                dispatchCsi(self, term, byte);
                self.state = .ground;
            },
            else => {
                self.state = .ground;
            },
        }
    }

    fn handleOsc(self: *Parser, byte: u8) void {
        switch (byte) {
            0x1B => self.state = .osc_escape, // ESC (expect \)
            0x07 => self.state = .ground, // BEL terminates OSC
            else => {}, // accumulate but we don't use OSC yet
        }
    }
};

// ---------------------------------------------------------------
// CSI Dispatch
// ---------------------------------------------------------------

fn dispatchCsi(parser: *Parser, term: *Terminal, final: u8) void {
    const p = parser.params;
    const n = parser.param_count;

    // Helper: get param with default
    const p1 = if (n >= 1 and p[0] > 0) p[0] else 1;
    const p2 = if (n >= 2 and p[1] > 0) p[1] else 1;

    if (parser.private_marker == '?') {
        // DEC private modes
        switch (final) {
            'h' => { // DECSET
                if (p[0] == 25) term.cursor_visible = true;
                if (p[0] == 1049) term.switchToAltScreen();
            },
            'l' => { // DECRST
                if (p[0] == 25) term.cursor_visible = false;
                if (p[0] == 1049) term.switchToMainScreen();
            },
            else => {},
        }
        return;
    }

    switch (final) {
        'A' => term.moveCursorUp(p1),
        'B' => term.moveCursorDown(p1),
        'C' => term.moveCursorForward(p1),
        'D' => term.moveCursorBack(p1),
        'E' => { // CNL — cursor next line
            term.cursor_col = 0;
            term.moveCursorDown(p1);
        },
        'F' => { // CPL — cursor previous line
            term.cursor_col = 0;
            term.moveCursorUp(p1);
        },
        'G' => { // CHA — cursor horizontal absolute
            term.cursor_col = if (p1 > 0) @min(p1 - 1, term.cols - 1) else 0;
        },
        'H', 'f' => { // CUP — cursor position
            term.cursor_row = if (p1 > 0) @min(p1 - 1, term.rows - 1) else 0;
            term.cursor_col = if (p2 > 0) @min(p2 - 1, term.cols - 1) else 0;
        },
        'J' => { // ED — erase display
            const mode = if (n >= 1) p[0] else 0;
            term.eraseDisplay(mode);
        },
        'K' => { // EL — erase line
            const mode = if (n >= 1) p[0] else 0;
            term.eraseLine(mode);
        },
        'L' => term.insertLines(p1),
        'M' => term.deleteLines(p1),
        'S' => term.scrollUp(p1),
        'T' => term.scrollDown(p1),
        '@' => term.insertChars(p1),
        'P' => term.deleteChars(p1),
        'X' => term.eraseChars(p1),
        'd' => { // VPA — vertical position absolute
            term.cursor_row = if (p1 > 0) @min(p1 - 1, term.rows - 1) else 0;
        },
        'm' => handleSGR(term, &parser.params, n),
        'r' => { // DECSTBM — set scrolling region
            const top = if (n >= 1 and p[0] > 0) p[0] - 1 else 0;
            const bot = if (n >= 2 and p[1] > 0) p[1] - 1 else term.rows - 1;
            term.scroll_top = @min(top, term.rows - 1);
            term.scroll_bottom = @min(bot, term.rows - 1);
            term.cursor_row = 0;
            term.cursor_col = 0;
        },
        's' => term.saveCursor(),
        'u' => term.restoreCursor(),
        'n' => { // DSR — device status report
            if (p[0] == 6) {
                // Report cursor position — we'd need an output callback for this
                // For now, ignore
            }
        },
        else => {}, // unrecognized
    }
}

// ---------------------------------------------------------------
// SGR (Select Graphic Rendition)
// ---------------------------------------------------------------

fn handleSGR(term: *Terminal, params: []const u16, count: u8) void {
    if (count == 0) {
        term.resetAttrs();
        return;
    }

    var i: u8 = 0;
    while (i < count) {
        const code = params[i];
        switch (code) {
            0 => term.resetAttrs(),
            1 => term.current_attrs.bold = true,
            2 => term.current_attrs.dim = true,
            3 => term.current_attrs.italic = true,
            4 => term.current_attrs.underline = true,
            5 => term.current_attrs.blink = true,
            7 => term.current_attrs.reverse = true,
            8 => term.current_attrs.hidden = true,
            9 => term.current_attrs.strikethrough = true,
            21 => term.current_attrs.bold = false,
            22 => {
                term.current_attrs.bold = false;
                term.current_attrs.dim = false;
            },
            23 => term.current_attrs.italic = false,
            24 => term.current_attrs.underline = false,
            25 => term.current_attrs.blink = false,
            27 => term.current_attrs.reverse = false,
            28 => term.current_attrs.hidden = false,
            29 => term.current_attrs.strikethrough = false,

            // Foreground colors
            30...37 => term.current_fg = palette_256[code - 30],
            39 => term.current_fg = Terminal.DEFAULT_FG,
            90...97 => term.current_fg = palette_256[code - 90 + 8],

            // Background colors
            40...47 => term.current_bg = palette_256[code - 40],
            49 => term.current_bg = Terminal.DEFAULT_BG,
            100...107 => term.current_bg = palette_256[code - 100 + 8],

            // Extended colors
            38 => { // foreground
                i += 1;
                if (i >= count) break;
                if (params[i] == 5 and i + 1 < count) {
                    // 256-color: ESC[38;5;{n}m
                    i += 1;
                    term.current_fg = palette_256[params[i]];
                } else if (params[i] == 2 and i + 3 < count) {
                    // Truecolor: ESC[38;2;{r};{g};{b}m
                    i += 1;
                    const r: u8 = @truncate(params[i]);
                    i += 1;
                    const g: u8 = @truncate(params[i]);
                    i += 1;
                    const b: u8 = @truncate(params[i]);
                    term.current_fg = .{ .r = r, .g = g, .b = b, .a = 255 };
                }
            },
            48 => { // background
                i += 1;
                if (i >= count) break;
                if (params[i] == 5 and i + 1 < count) {
                    i += 1;
                    term.current_bg = palette_256[params[i]];
                } else if (params[i] == 2 and i + 3 < count) {
                    i += 1;
                    const r: u8 = @truncate(params[i]);
                    i += 1;
                    const g: u8 = @truncate(params[i]);
                    i += 1;
                    const b: u8 = @truncate(params[i]);
                    term.current_bg = .{ .r = r, .g = g, .b = b, .a = 255 };
                }
            },
            else => {},
        }
        i += 1;
    }
}
