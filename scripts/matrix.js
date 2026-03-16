// Matrix rain effect
clear();
const cols = term.cols;
const rows = term.rows;
const chars = "abcdefghijklmnopqrstuvwxyz0123456789@#$%&*";
const drops = [];

for (let i = 0; i < cols; i++) {
    drops[i] = Math.floor(Math.random() * rows);
}

for (let frame = 0; frame < 120; frame++) {
    for (let i = 0; i < cols; i++) {
        if (Math.random() > 0.95) {
            const ch = chars[Math.floor(Math.random() * chars.length)];
            const row = drops[i] % rows;
            term.cursor(row + 1, i + 1);
            term.write("\x1b[1;32m" + ch);

            // Fade the previous character
            if (row > 0) {
                term.cursor(row, i + 1);
                const prev = chars[Math.floor(Math.random() * chars.length)];
                term.write("\x1b[0;32m" + prev);
            }

            drops[i]++;
        }
    }
    sleep(50);
}

term.reset();
term.cursor(rows, 1);
print("");
