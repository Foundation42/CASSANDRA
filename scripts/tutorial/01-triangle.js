// Tutorial 01 — Hello Triangle
exec("../scripts/lib/scene.js");

const scene = new Scene(0, 400, 400);
scene.position(50, 30);
scene.background(20, 20, 30);

scene.text({ x: 10, y: 10, label: "01 - Hello Triangle", size: 16, color: gfx.rgb(200, 200, 200) });

// A simple triangle
const tri = scene.triangle({
    x: 100, y: 300,    // bottom left
    x2: 300, y2: 300,   // bottom right
    x3: 200, y3: 100,   // top center (note: reversed winding for Raylib)
    color: gfx.rgb(0, 255, 100)
});

scene.run();
