// Tutorial 07 — Particle system
gfx.create(0, 500, 400);
gfx.move(0, 50, 30);

const MAX_PARTICLES = 300;
const particles = [];

function spawn(x, y) {
    return {
        x: x, y: y,
        vx: (Math.random() - 0.5) * 4,
        vy: -2 - Math.random() * 4,
        life: 1.0,
        decay: 0.005 + Math.random() * 0.015,
        r: 200 + Math.floor(Math.random() * 55),
        g: Math.floor(Math.random() * 200),
        b: Math.floor(Math.random() * 50),
    };
}

// Pre-populate
for (let i = 0; i < 50; i++) {
    particles.push(spawn(250, 350));
}

let t = 0;
while (true) {
    gfx.begin(0);
    gfx.clear(5, 5, 10);
    gfx.text(10, 10, "07 - Particles", 16, gfx.rgb(200, 200, 200));

    // Spawn new particles
    const sx = 250 + Math.sin(t * 0.03) * 100;
    for (let i = 0; i < 3; i++) {
        if (particles.length < MAX_PARTICLES) {
            particles.push(spawn(sx, 350));
        }
    }

    // Update and draw
    for (let i = particles.length - 1; i >= 0; i--) {
        const p = particles[i];
        p.x += p.vx;
        p.y += p.vy;
        p.vy += 0.03; // gravity
        p.life -= p.decay;

        if (p.life <= 0) {
            particles.splice(i, 1);
            continue;
        }

        const alpha = Math.floor(p.life * 255);
        const size = p.life * 4;
        gfx.circle(p.x, p.y, size, gfx.rgba(p.r, p.g, p.b, alpha));
    }

    gfx.text(10, 380, particles.length + " particles", 10, gfx.rgb(100, 100, 100));
    gfx.end(0);
    t++;
    sleep(16);
}
