// System information display
clear();
term.color("cyan");
print("╔══════════════════════════════════════╗");
print("║       CASSANDRA System Info          ║");
print("╠══════════════════════════════════════╣");
term.reset();

const info = [
    ["Engine",    "QuickJS 2025-09-13"],
    ["Terminal",  term.cols + "x" + term.rows],
    ["Platform",  "Zig + Raylib"],
    ["Time",      new Date().toISOString()],
    ["Uptime",    Math.floor(Date.now() / 1000) + "s"],
];

for (const [key, val] of info) {
    term.color("cyan");
    term.write("║ ");
    term.color("yellow");
    term.write(key.padEnd(12));
    term.reset();
    term.write(val.padEnd(25));
    term.color("cyan");
    print("║");
}

term.color("cyan");
print("╚══════════════════════════════════════╝");
term.reset();
print("");
