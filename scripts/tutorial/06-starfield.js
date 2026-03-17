// Tutorial 06 — Starfield (classic demo effect)
gfx.create(0, 500, 400);
gfx.move(0, 50, 30);

const NUM_STARS = 200;
const cx = 250, cy = 200;
const stars = [];

for (let i = 0; i < NUM_STARS; i++) {
    stars.push({
        x: (Math.random() - 0.5) * 10,
        y: (Math.random() - 0.5) * 10,
        z: Math.random() * 10,
        speed: 0.02 + Math.random() * 0.05
    });
}

let t = 0;
while (true) {
    gfx.begin(0);
    gfx.clear(0, 0, 5);

    gfx.text(10, 10, "06 - Starfield", 16, gfx.rgb(200, 200, 200));

    for (const star of stars) {
        star.z -= star.speed;
        if (star.z <= 0.01) {
            star.x = (Math.random() - 0.5) * 10;
            star.y = (Math.random() - 0.5) * 10;
            star.z = 10;
        }

        const sx = cx + (star.x / star.z) * 100;
        const sy = cy + (star.y / star.z) * 100;
        const brightness = Math.floor(255 * (1 - star.z / 10));
        const size = Math.max(1, 3 - star.z * 0.3);

        if (sx > 0 && sx < 500 && sy > 0 && sy < 400) {
            gfx.circle(sx, sy, size, gfx.rgb(brightness, brightness, brightness));
        }
    }

    gfx.text(10, 380, NUM_STARS + " stars", 10, gfx.rgb(100, 100, 100));
    gfx.end(0);
    t++;
    sleep(16);
}
