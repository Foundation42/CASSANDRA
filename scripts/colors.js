// Color test — show all 256 terminal colors
term.color("cyan");
print("256 Color Palette");
print("=================");
term.reset();
print("");

// Standard 16 colors
for (let i = 0; i < 16; i++) {
    term.write("\x1b[48;5;" + i + "m  ");
    if (i === 7) { term.reset(); print(""); }
}
term.reset();
print("");
print("");

// 6x6x6 color cube (216 colors)
for (let g = 0; g < 6; g++) {
    for (let r = 0; r < 6; r++) {
        for (let b = 0; b < 6; b++) {
            const idx = 16 + r * 36 + g * 6 + b;
            term.write("\x1b[48;5;" + idx + "m ");
        }
        term.write("\x1b[0m ");
    }
    term.reset();
    print("");
}
print("");

// Grayscale ramp
for (let i = 232; i < 256; i++) {
    term.write("\x1b[48;5;" + i + "m  ");
}
term.reset();
print("");
