// Tutorial 04 — Scene composition
exec("../scripts/lib/scene.js");

const scene = new Scene(0, 400, 400);
scene.position(50, 30);
scene.background(10, 10, 25);

scene.text({ x: 10, y: 10, label: "04 - Composition", size: 16, color: gfx.rgb(200, 200, 200) });

// Solar system
// Sun
scene.circle({ x: 200, y: 200, r: 25, color: gfx.rgb(255, 200, 50) })
    .behave("pulse", { base: 25, amplitude: 3, speed: 1 });

// Planet 1 — orbits fast
scene.circle({ x: 260, y: 200, r: 8, color: gfx.rgb(100, 150, 255) })
    .behave(function(obj, t) {
        obj.x = 200 + Math.cos(t * 3) * 60;
        obj.y = 200 + Math.sin(t * 3) * 60;
    });

// Planet 2 — orbits slower with moon
scene.circle({ x: 320, y: 200, r: 12, color: gfx.rgb(50, 200, 100) })
    .behave(function(obj, t) {
        obj.x = 200 + Math.cos(t * 1.5) * 110;
        obj.y = 200 + Math.sin(t * 1.5) * 110;
    });

// Moon — orbits planet 2
scene.circle({ x: 330, y: 200, r: 4, color: gfx.rgb(200, 200, 200) })
    .behave(function(obj, t) {
        const px = 200 + Math.cos(t * 1.5) * 110;
        const py = 200 + Math.sin(t * 1.5) * 110;
        obj.x = px + Math.cos(t * 8) * 20;
        obj.y = py + Math.sin(t * 8) * 20;
    });

// Planet 3 — large, slow
scene.circle({ x: 380, y: 200, r: 15, color: gfx.rgb(200, 100, 50) })
    .behave(function(obj, t) {
        obj.x = 200 + Math.cos(t * 0.7) * 160;
        obj.y = 200 + Math.sin(t * 0.7) * 160;
    })
    .behave("color-cycle", { speed: 0.3 });

// Orbit lines (static)
for (const r of [60, 110, 160]) {
    for (let a = 0; a < Math.PI * 2; a += 0.15) {
        scene.circle({
            x: 200 + Math.cos(a) * r,
            y: 200 + Math.sin(a) * r,
            r: 1,
            color: gfx.rgba(80, 80, 80, 100)
        });
    }
}

scene.run();
