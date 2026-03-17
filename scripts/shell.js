// CASSANDRA Shell — the command interpreter
// This is the default program that runs when the terminal opens.

term.color("green");
print("CASSANDRA Terminal v1.0");
term.color("cyan");
print("-----------------------------");
term.reset();
print("Type help for commands\n");

const SCRIPT_DIRS = ["../scripts", "scripts"];

while (true) {
    // Prompt
    term.color("green");
    term.write("> ");
    term.reset();

    // Read command
    const line = term.readLine().trim();
    if (!line) continue;

    // Parse pipes
    const stages = line.split("|").map(s => s.trim()).filter(s => s.length > 0);

    if (stages.length === 0) continue;

    // Single command — check built-ins first
    if (stages.length === 1) {
        const cmd = stages[0];
        const spaceIdx = cmd.indexOf(" ");
        const name = spaceIdx >= 0 ? cmd.substring(0, spaceIdx) : cmd;
        const args = spaceIdx >= 0 ? cmd.substring(spaceIdx + 1) : "";

        if (name === "help") {
            showHelp();
            continue;
        } else if (name === "clear") {
            clear();
            continue;
        } else if (name === "quit" || name === "exit") {
            break;
        } else if (name === "js") {
            if (args) {
                try {
                    const result = eval(args);
                    if (result !== undefined) {
                        term.write("\x1b[0;37m");
                        print(String(result));
                        term.reset();
                    }
                } catch (e) {
                    term.color("red");
                    print(String(e));
                    term.reset();
                }
            }
            continue;
        }
    }

    // Pipeline execution
    let stdin = "";
    let piped = false;
    let failed = false;

    for (let i = 0; i < stages.length; i++) {
        const cmd = stages[i];
        const spaceIdx = cmd.indexOf(" ");
        const name = spaceIdx >= 0 ? cmd.substring(0, spaceIdx) : cmd;
        const args = spaceIdx >= 0 ? cmd.substring(spaceIdx + 1) : "";
        const isLast = (i === stages.length - 1);

        // Find script — or fall back to host binary
        const scriptPath = findScript(name);
        if (!scriptPath) {
            // Try as host system command
            if (stages.length === 1) {
                system(cmd);
                failed = true; // not really failed, just skip the rest
                break;
            } else {
                term.color("red");
                print("Unknown command: " + name);
                term.reset();
                failed = true;
                break;
            }
        }

        // Set globals for the script
        globalThis.__args = args;
        globalThis.__stdin = stdin;
        globalThis.__piped = piped;

        try {
            if (!isLast) {
                stdin = exec(scriptPath, true) || "";
                piped = true;
            } else {
                exec(scriptPath);
            }
        } catch (e) {
            if (e && e.message === "interrupted") {
                // Ctrl+C — silently stop
                break;
            }
            throw e;
        }
    }
}

// Clean exit
clear();

// ---------------------------------------------------------------
// Helper functions
// ---------------------------------------------------------------

function findScript(name) {
    for (const dir of SCRIPT_DIRS) {
        const path = dir + "/" + name + ".js";
        if (fs.exists(path)) return path;
    }
    return null;
}

function showHelp() {
    term.color("cyan");
    print("Built-in commands:");
    term.reset();
    print("  \x1b[1;33mclear\x1b[0m         - Clear terminal");
    print("  \x1b[1;33mjs <code>\x1b[0m     - Evaluate JavaScript");
    print("  \x1b[1;33mquit\x1b[0m          - Close terminal");
    print("");
    term.color("cyan");
    print("Programs: (drop .js files in scripts/)");
    term.reset();

    // List available programs
    for (const dir of SCRIPT_DIRS) {
        const files = fs.listDir(dir);
        if (files) {
            const programs = files
                .filter(f => f.endsWith(".js") && f !== "shell.js")
                .map(f => f.slice(0, -3))
                .sort();
            for (const p of programs) {
                print("  \x1b[1;33m" + p + "\x1b[0m");
            }
            break;
        }
    }

    print("");
    term.color("cyan");
    print("Pipes:  cmd1 | cmd2 | cmd3");
    print("JS API: print() clear() sleep() exec() term.* fs.*");
    term.reset();
    print("  \x1b[33m__stdin\x1b[0m / \x1b[33m__piped\x1b[0m  - piped input from previous stage");
}
