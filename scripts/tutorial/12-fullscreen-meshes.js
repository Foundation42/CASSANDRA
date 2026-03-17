// Tutorial 12 — Full viewport meshes, transparent, floating over the map
exec("../scripts/lib/mesh.js");

const sphere = Mesh.icosphere(1.0, 2);
const box = Mesh.box(1.5, 1.5, 1.5);
const plane = Mesh.plane(3, 3, 6, 6);

// Full viewport — use gfx.rgb for Raylib screen size query not available,
// so use a large fixed size
gfx.create(0, 1920, 1080);
gfx.move(0, 0, 0);

const CYAN = gfx.rgb(50, 200, 220);
const RED = gfx.rgb(220, 80, 60);
const GOLD = gfx.rgb(220, 180, 50);
const LIGHT = [0.5, -0.7, 0.5];

let t = 0;
while (true) {
    gfx.begin(0);
    // No clear — transparent background, map shows through

    const camX = Math.cos(t * 0.01) * 8;
    const camZ = Math.sin(t * 0.01) * 8;
    gfx.begin3d(camX, 4, camZ, 0, 0, 0, 45);

    // Sphere
    sphere.draw(-3, 0, 0, CYAN, LIGHT);

    // Box
    box.draw(0, 0, 0, RED, LIGHT);

    // Animated wave plane
    for (let i = 0; i < plane.vertices.length; i++) {
        const v = plane.vertices[i];
        v[1] = Math.sin(v[0] * 2 + t * 0.03) * 0.2 + Math.cos(v[2] * 2 + t * 0.02) * 0.15;
    }
    plane.computeNormals();
    plane.draw(3, 0, 0, GOLD, LIGHT);

    gfx.end3d();
    gfx.end(0);
    t++;
    sleep(16);
}
