// scene.js — retained mode scene graph with behaviors
// Built on top of the immediate-mode gfx.* API

function Scene(id, w, h) {
    this.id = id || 0;
    this.w = w || 300;
    this.h = h || 300;
    this.objects = [];
    this.t = 0;
    this.bg = null; // null = transparent
    this.cam = { dist: 5.0, pitch: 0.4, yaw: 0 };
    gfx.create(this.id, this.w, this.h);
}

Scene.prototype.background = function(r, g, b) {
    this.bg = [r, g, b];
    return this;
};

Scene.prototype.position = function(x, y) {
    gfx.move(this.id, x, y);
    return this;
};

Scene.prototype.cube = function(props) {
    const obj = new SceneObject("cube", props);
    this.objects.push(obj);
    return obj;
};

Scene.prototype.sphere = function(props) {
    const obj = new SceneObject("sphere", props);
    this.objects.push(obj);
    return obj;
};

Scene.prototype.line = function(props) {
    const obj = new SceneObject("line", props);
    this.objects.push(obj);
    return obj;
};

Scene.prototype.rect = function(props) {
    const obj = new SceneObject("rect", props);
    this.objects.push(obj);
    return obj;
};

Scene.prototype.circle = function(props) {
    const obj = new SceneObject("circle", props);
    this.objects.push(obj);
    return obj;
};

Scene.prototype.text = function(props) {
    const obj = new SceneObject("text", props);
    this.objects.push(obj);
    return obj;
};

Scene.prototype.run = function(fps) {
    const interval = Math.floor(1000 / (fps || 60));
    let last = Date.now();

    while (true) {
        const now = Date.now();
        const dt = (now - last) / 1000;
        last = now;
        this.t += dt;

        // Update behaviors
        for (const obj of this.objects) {
            for (const b of obj.behaviors) {
                b.fn(obj, this.t, dt, b.opts);
            }
        }

        // Render
        gfx.begin(this.id);
        if (this.bg) gfx.clear(this.bg[0], this.bg[1], this.bg[2]);
        gfx.camera(this.id, this.cam.dist, this.cam.pitch, this.cam.yaw);

        for (const obj of this.objects) {
            if (!obj.visible) continue;
            this._draw(obj);
        }

        gfx.end(this.id);
        sleep(interval);
    }
};

Scene.prototype._draw = function(obj) {
    const c = obj.color || gfx.rgb(255, 255, 255);

    switch (obj.type) {
        case "cube":
            gfx.cube(obj.x, obj.y, obj.z, obj.size || 1, c, obj.rx || 0, obj.ry || 0);
            break;
        case "line":
            gfx.line(obj.x, obj.y, obj.x2 || 0, obj.y2 || 0, c, obj.thick || 1);
            break;
        case "rect":
            gfx.rect(obj.x, obj.y, obj.w || 50, obj.h || 50, c);
            break;
        case "circle":
            gfx.circle(obj.x, obj.y, obj.r || 20, c);
            break;
        case "text":
            gfx.text(obj.x, obj.y, obj.label || "", obj.size || 12, c);
            break;
    }
};

// ---------------------------------------------------------------
// Scene Object
// ---------------------------------------------------------------

function SceneObject(type, props) {
    this.type = type;
    this.x = 0; this.y = 0; this.z = 0;
    this.rx = 0; this.ry = 0; this.rz = 0;
    this.size = 1;
    this.w = 50; this.h = 50; this.r = 20;
    this.x2 = 0; this.y2 = 0;
    this.color = null;
    this.label = "";
    this.thick = 1;
    this.visible = true;
    this.behaviors = [];
    this.data = {}; // user data for behaviors

    // Apply initial props
    if (props) Object.assign(this, props);
}

SceneObject.prototype.behave = function(nameOrFn, opts) {
    if (typeof nameOrFn === "function") {
        this.behaviors.push({ fn: nameOrFn, opts: opts || {} });
    } else {
        // Load from behaviors/<name>.js
        const paths = ["../scripts/behaviors/" + nameOrFn + ".js", "scripts/behaviors/" + nameOrFn + ".js"];
        let loaded = false;
        for (const path of paths) {
            if (fs.exists(path)) {
                const code = fs.readFile(path);
                if (code) {
                    const fn = new Function("return (" + code + ")")();
                    this.behaviors.push({ fn: fn, opts: opts || {} });
                    loaded = true;
                    break;
                }
            }
        }
        if (!loaded) print("Behavior not found: " + nameOrFn);
    }
    return this;
};

// Make available globally
globalThis.Scene = Scene;
globalThis.SceneObject = SceneObject;
