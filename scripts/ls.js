// List available programs
const dirs = ["../scripts", "scripts"];
let files = null;

for (const dir of dirs) {
    files = fs.listDir(dir);
    if (files) break;
}

if (!files || files.length === 0) {
    print("No programs found.");
} else {
    term.color("cyan");
    print("Available programs:");
    print("-------------------");
    term.reset();

    const programs = files
        .filter(f => f.endsWith(".js"))
        .map(f => f.slice(0, -3))
        .sort();

    for (const name of programs) {
        term.write("  ");
        term.color("yellow");
        print(name);
        term.reset();
    }
    print("");
    print(programs.length + " program(s)");
}
