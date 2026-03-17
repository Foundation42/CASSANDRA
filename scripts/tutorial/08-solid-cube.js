// Tutorial 08 — Solid cube using Raylib's real 3D pipeline
gfx.create(0, 400, 400);
gfx.move(0, 50, 30);

const GREEN = gfx.rgb(50, 200, 100);
const WHITE = gfx.rgb(200, 200, 200);

let t = 0;
while (true) {
    gfx.begin(0);
    gfx.clear(15, 15, 25);

    // 2D title (before 3D mode)
    gfx.text(10, 10, "08 - Solid Cube (GPU)", 16, WHITE);

    // Enter 3D mode: camera orbits around origin
    const camX = Math.cos(t * 0.02) * 5;
    const camZ = Math.sin(t * 0.02) * 5;
    gfx.begin3d(camX, 3, camZ, 0, 0, 0, 45);

    // Solid cube at origin — Raylib handles depth, lighting, everything
    gfx.solidCube(0, 0, 0, 2, GREEN);

    // Wireframe cube slightly larger (outline effect)
    gfx.cube(0, 0, 0, 2.02, gfx.rgb(100, 255, 150));

    gfx.end3d();

    // 2D overlay after 3D
    gfx.text(10, 380, "Frame " + t, 10, gfx.rgb(100, 100, 100));
    gfx.end(0);
    t++;
    sleep(16);
}
