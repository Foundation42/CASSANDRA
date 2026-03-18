// Tutorial 09 — Multiple solid cubes with orbiting camera
exec("../scripts/lib/scene.js");

const scene = new Scene(0, 450, 400);
scene.position(50, 30);
scene.background(10, 10, 20);

scene.text({ x: 10, y: 10, label: "09 - Lit Beautiful Scene", size: 16, color: gfx.rgb(200, 200, 200) });

// Three solid cubes at different positions
scene.cube({ solid: true, x: -2.5, y: 0, z: 0, size: 1.2, color: gfx.rgb(255, 80, 80) });
scene.cube({ solid: true, x: 0, y: 0, z: 0, size: 1.5, color: gfx.rgb(80, 200, 80) })
    .behave("bounce", { amplitude: 0.3, speed: 2 });
scene.cube({ solid: true, x: 2.5, y: 0, z: 0, size: 1.0, color: gfx.rgb(80, 80, 255) })
    .behave("color-cycle", { speed: 0.5 });

scene.cam.dist = 8;
scene.cam.pitch = 0.4;

// Slowly orbit camera
scene.text({ x: 10, y: 380, label: "", size: 10, color: gfx.rgb(100, 100, 100) })
    .behave(function(obj, t) {
        scene.cam.yaw = t * 0.3;
    });

scene.run();
