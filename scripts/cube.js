// Spinning cube — floating over the map
exec("../scripts/lib/scene.js");

const scene = new Scene(0, 300, 300);
scene.position(100, 50);
scene.background(-1, 0, 0); // transparent

scene.cube({ size: 1.5, color: gfx.rgb(0, 255, 100) })
    .behave("rotate")
    .behave("pulse");

scene.text({ x: 8, y: 8, label: "CASSANDRA OS", size: 20, color: gfx.rgb(0, 200, 255) });

scene.run();
