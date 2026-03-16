// CASSANDRA Editor — a mini nano-like text editor
// Usage: edit <filename>

const filename = globalThis.__args || "";
if (!filename) {
    print("\x1b[1;31mUsage:\x1b[0m edit <filename>");
    // Can't use raw mode if we bail early
} else {
    runEditor(filename);
}

function runEditor(fname) {
    const COLS = term.cols;
    const ROWS = term.rows;
    const EDIT_ROWS = ROWS - 3; // status bar + help line + 1

    // Load file or start empty
    let lines = [""];
    if (fs.exists(fname)) {
        const content = fs.readFile(fname);
        if (content) {
            lines = content.split("\n");
            if (lines.length === 0) lines = [""];
        }
    }

    let cx = 0;        // cursor x (column in current line)
    let cy = 0;        // cursor y (line index)
    let scroll = 0;    // first visible line
    let dirty = false;  // unsaved changes
    let message = fs.exists(fname) ? "Opened " + fname : "New file: " + fname;
    let running = true;

    term.rawMode(1);
    clear();
    draw();

    while (running) {
        const key = term.getKey();
        if (!key) continue;

        message = "";

        if (key === "ctrl-x" || key === "ctrl-q") {
            if (dirty) {
                message = "Unsaved changes! Ctrl-Q again to quit, Ctrl-S to save";
                draw();
                const confirm = term.getKey();
                if (confirm === "ctrl-q" || confirm === "ctrl-x") {
                    running = false;
                } else if (confirm === "ctrl-s") {
                    saveFile();
                }
            } else {
                running = false;
            }
        } else if (key === "ctrl-s" || key === "ctrl-o") {
            saveFile();
        } else if (key === "ctrl-k") {
            // Delete current line
            if (lines.length > 1) {
                lines.splice(cy, 1);
                if (cy >= lines.length) cy = lines.length - 1;
                cx = Math.min(cx, lines[cy].length);
                dirty = true;
                message = "Line deleted";
            }
        } else if (key === "ctrl-g") {
            message = "L:" + (cy+1) + "/" + lines.length + " C:" + (cx+1) + " | " + fname;
        } else if (key === "up") {
            if (cy > 0) { cy--; cx = Math.min(cx, lines[cy].length); }
        } else if (key === "down") {
            if (cy < lines.length - 1) { cy++; cx = Math.min(cx, lines[cy].length); }
        } else if (key === "left") {
            if (cx > 0) cx--;
            else if (cy > 0) { cy--; cx = lines[cy].length; }
        } else if (key === "right") {
            if (cx < lines[cy].length) cx++;
            else if (cy < lines.length - 1) { cy++; cx = 0; }
        } else if (key === "home") {
            cx = 0;
        } else if (key === "end") {
            cx = lines[cy].length;
        } else if (key === "pageup") {
            cy = Math.max(0, cy - EDIT_ROWS);
            cx = Math.min(cx, lines[cy].length);
        } else if (key === "pagedown") {
            cy = Math.min(lines.length - 1, cy + EDIT_ROWS);
            cx = Math.min(cx, lines[cy].length);
        } else if (key === "enter") {
            // Split line at cursor
            const rest = lines[cy].substring(cx);
            lines[cy] = lines[cy].substring(0, cx);
            cy++;
            lines.splice(cy, 0, rest);
            cx = 0;
            dirty = true;
        } else if (key === "backspace") {
            if (cx > 0) {
                lines[cy] = lines[cy].substring(0, cx - 1) + lines[cy].substring(cx);
                cx--;
                dirty = true;
            } else if (cy > 0) {
                // Join with previous line
                cx = lines[cy - 1].length;
                lines[cy - 1] += lines[cy];
                lines.splice(cy, 1);
                cy--;
                dirty = true;
            }
        } else if (key === "delete") {
            if (cx < lines[cy].length) {
                lines[cy] = lines[cy].substring(0, cx) + lines[cy].substring(cx + 1);
                dirty = true;
            } else if (cy < lines.length - 1) {
                lines[cy] += lines[cy + 1];
                lines.splice(cy + 1, 1);
                dirty = true;
            }
        } else if (key === "tab") {
            lines[cy] = lines[cy].substring(0, cx) + "    " + lines[cy].substring(cx);
            cx += 4;
            dirty = true;
        } else if (key.length === 1) {
            // Regular character
            lines[cy] = lines[cy].substring(0, cx) + key + lines[cy].substring(cx);
            cx++;
            dirty = true;
        }

        // Scroll to keep cursor visible
        if (cy < scroll) scroll = cy;
        if (cy >= scroll + EDIT_ROWS) scroll = cy - EDIT_ROWS + 1;

        draw();
    }

    term.rawMode(0);
    clear();

    function draw() {
        term.write("\x1b[?25l"); // hide cursor during redraw

        // Title bar
        term.cursor(1, 1);
        term.write("\x1b[7m"); // reverse video
        const title = " CASSANDRA Editor | " + fname + (dirty ? " [modified]" : "") + " ";
        term.write(title.padEnd(COLS));
        term.write("\x1b[0m");

        // Text area
        for (let r = 0; r < EDIT_ROWS; r++) {
            term.cursor(r + 2, 1);
            const lineIdx = scroll + r;
            if (lineIdx < lines.length) {
                const line = lines[lineIdx];
                const visible = line.substring(0, COLS);
                term.write("\x1b[K" + visible);
            } else {
                term.write("\x1b[36m~\x1b[0m\x1b[K");
            }
        }

        // Status bar
        term.cursor(ROWS - 1, 1);
        term.write("\x1b[7m");
        const status = " L:" + (cy+1) + "/" + lines.length + " C:" + (cx+1) + " ";
        const msg = message ? " " + message : "";
        term.write((status + msg).padEnd(COLS));
        term.write("\x1b[0m");

        // Help line
        term.cursor(ROWS, 1);
        term.write("\x1b[36m ^S\x1b[0m Save  \x1b[36m^X\x1b[0m Exit  \x1b[36m^K\x1b[0m Del Line  \x1b[36m^G\x1b[0m Info\x1b[K");

        // Position cursor
        const screenRow = cy - scroll + 2;
        const screenCol = cx + 1;
        term.cursor(screenRow, screenCol);
        term.write("\x1b[?25h"); // show cursor
    }

    function saveFile() {
        const content = lines.join("\n");
        if (fs.writeFile(fname, content)) {
            dirty = false;
            message = "Saved " + lines.length + " lines to " + fname;
        } else {
            message = "ERROR: Could not save " + fname;
        }
    }
}
