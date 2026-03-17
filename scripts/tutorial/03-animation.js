// Tutorial 03 — Animation with behaviors
exec("../scripts/lib/scene.js");

const scene = new Scene(0, 400, 400);
scene.position(50, 30);
scene.background(20, 20, 30);

scene.text({ x: 10, y: 10, label: "03 - Animation", size: 16, color: gfx.rgb(200, 200, 200) });

// Bouncing circle
scene.circle({ x: 200, y: 200, r: 30, color: gfx.rgb(255, 100, 50) })
    .behave(function(obj, t) {
        obj.x = 200 + Math.sin(t * 2) * 120;
        obj.y = 200 + Math.cos(t * 3) * 80;
    })
    .behave("color-cycle");

// Pulsing rectangle
scene.rect({ x: 50, y: 300, w: 80, h: 50, color: gfx.rgb(100, 200, 255) })
    .behave(function(obj, t) {
        obj.w = 80 + Math.sin(t * 4) * 30;
        obj.h = 50 + Math.cos(t * 3) * 20;
    });

// Spinning triangle
scene.triangle({ x: 300, y: 100, x2: 350, y2: 180, x3: 250, y3: 180, color: gfx.rgb(0, 255, 100) })
    .behave(function(obj, t) {
        const cx = 300, cy = 140, r = 60;
        const a = t * 2;
        obj.x = cx + Math.cos(a) * r;
        obj.y = cy + Math.sin(a) * r;
        obj.x2 = cx + Math.cos(a + 2.094) * r;
        obj.y2 = cy + Math.sin(a + 2.094) * r;
        obj.x3 = cx + Math.cos(a + 4.189) * r;
        obj.y3 = cy + Math.sin(a + 4.189) * r;
    });

scene.run();
