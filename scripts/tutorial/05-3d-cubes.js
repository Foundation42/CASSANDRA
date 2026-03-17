// Tutorial 05 — 3D cubes with multiple behaviors
exec("../scripts/lib/scene.js");

const scene = new Scene(0, 400, 400);
scene.position(50, 30);
scene.background(10, 10, 25);

scene.text({ x: 10, y: 10, label: "05 - 3D Cubes", size: 16, color: gfx.rgb(200, 200, 200) });

// Grid of cubes with different behaviors
const colors = [
    gfx.rgb(255, 50, 50),   // red
    gfx.rgb(50, 255, 50),   // green
    gfx.rgb(50, 50, 255),   // blue
    gfx.rgb(255, 255, 50),  // yellow
    gfx.rgb(255, 50, 255),  // magenta
    gfx.rgb(50, 255, 255),  // cyan
];

for (let i = 0; i < 6; i++) {
    const x = (i % 3 - 1) * 2.5;
    const z = (Math.floor(i / 3) - 0.5) * 2.5;
    scene.cube({ x: x, y: 0, z: z, size: 0.8, color: colors[i] })
        .behave("rotate", { speed: 1.0 + i * 0.5 })
        .behave(function(obj, t) {
            obj.y = Math.sin(t * 2 + obj.x) * 0.5;
        });
}

scene.cam.dist = 8;
scene.cam.pitch = 0.5;

// Slowly orbit the camera
scene.text({ x: 10, y: 380, label: "6 cubes, each with rotate + wave", size: 10, color: gfx.rgb(100, 100, 100) });

// Camera behavior via manual yaw update
const camLabel = scene.text({ x: 10, y: 365, label: "", size: 10, color: gfx.rgb(150, 150, 150) });
camLabel.behave(function(obj, t) {
    scene.cam.yaw = t * 0.3;
    obj.label = "cam yaw: " + (scene.cam.yaw % 6.28).toFixed(2);
});

scene.run();
