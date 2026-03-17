// Tutorial 02 — Colored shapes
exec("../scripts/lib/scene.js");

const scene = new Scene(0, 400, 400);
scene.position(50, 30);
scene.background(20, 20, 30);

scene.text({ x: 10, y: 10, label: "02 - Colors", size: 16, color: gfx.rgb(200, 200, 200) });

// RGB triangles
scene.triangle({ x: 80, y: 200, x2: 200, y2: 200, x3: 140, y3: 100, color: gfx.rgb(255, 0, 0) });
scene.triangle({ x: 150, y: 250, x2: 270, y2: 250, x3: 210, y3: 150, color: gfx.rgb(0, 255, 0) });
scene.triangle({ x: 220, y: 300, x2: 340, y2: 300, x3: 280, y3: 200, color: gfx.rgb(0, 100, 255) });

// Colored rectangles
scene.rect({ x: 50, y: 310, w: 60, h: 40, color: gfx.rgb(255, 255, 0) });
scene.rect({ x: 130, y: 310, w: 60, h: 40, color: gfx.rgb(255, 0, 255) });
scene.rect({ x: 210, y: 310, w: 60, h: 40, color: gfx.rgb(0, 255, 255) });

// Circles
scene.circle({ x: 320, y: 330, r: 25, color: gfx.rgb(255, 128, 0) });

scene.run();
