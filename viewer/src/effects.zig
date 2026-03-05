const std = @import("std");
const rl = @import("rl.zig");
const constants = @import("constants.zig");

/// Geiss-style trail feedback + bloom post-process.
/// Toggle with T (trails) and B (bloom).
pub const Effects = struct {
    // Trail: ping-pong between two render textures
    trail_a: rl.c.RenderTexture2D = undefined,
    trail_b: rl.c.RenderTexture2D = undefined,
    which: bool = false,

    // Bloom: two-pass Gaussian blur
    bloom_tex: rl.c.RenderTexture2D = undefined,
    scratch_tex: rl.c.RenderTexture2D = undefined,
    blur_shader: rl.c.Shader = undefined,
    blur_res_loc: c_int = -1,
    blur_dir_loc: c_int = -1,

    // Scene capture
    scene_tex: rl.c.RenderTexture2D = undefined,

    trails_on: bool = false,
    bloom_on: bool = false,
    trail_fade: f32 = 0.92,

    width: c_int = 0,
    height: c_int = 0,
    initialized: bool = false,

    pub fn init(self: *Effects, w: c_int, h: c_int) void {
        self.width = w;
        self.height = h;
        self.scene_tex = rl.c.LoadRenderTexture(w, h);
        self.trail_a = rl.c.LoadRenderTexture(w, h);
        self.trail_b = rl.c.LoadRenderTexture(w, h);
        self.bloom_tex = rl.c.LoadRenderTexture(w, h);
        self.scratch_tex = rl.c.LoadRenderTexture(w, h);

        // Bilinear filtering on all render textures — critical for smooth bloom sampling
        rl.c.SetTextureFilter(self.scene_tex.texture, rl.c.TEXTURE_FILTER_BILINEAR);
        rl.c.SetTextureFilter(self.trail_a.texture, rl.c.TEXTURE_FILTER_BILINEAR);
        rl.c.SetTextureFilter(self.trail_b.texture, rl.c.TEXTURE_FILTER_BILINEAR);
        rl.c.SetTextureFilter(self.bloom_tex.texture, rl.c.TEXTURE_FILTER_BILINEAR);
        rl.c.SetTextureFilter(self.scratch_tex.texture, rl.c.TEXTURE_FILTER_BILINEAR);

        rl.c.BeginTextureMode(self.trail_a);
        rl.c.ClearBackground(rl.c.BLACK);
        rl.c.EndTextureMode();
        rl.c.BeginTextureMode(self.trail_b);
        rl.c.ClearBackground(rl.c.BLACK);
        rl.c.EndTextureMode();

        self.blur_shader = rl.c.LoadShaderFromMemory(null, blur_fs);
        self.blur_res_loc = rl.c.GetShaderLocation(self.blur_shader, "resolution");
        self.blur_dir_loc = rl.c.GetShaderLocation(self.blur_shader, "direction");
        self.initialized = true;
    }

    pub fn deinit(self: *Effects) void {
        if (!self.initialized) return;
        rl.c.UnloadRenderTexture(self.scene_tex);
        rl.c.UnloadRenderTexture(self.trail_a);
        rl.c.UnloadRenderTexture(self.trail_b);
        rl.c.UnloadRenderTexture(self.bloom_tex);
        rl.c.UnloadRenderTexture(self.scratch_tex);
        rl.c.UnloadShader(self.blur_shader);
        self.initialized = false;
    }

    pub fn handleResize(self: *Effects, w: c_int, h: c_int) void {
        if (w == self.width and h == self.height) return;
        if (self.initialized) self.deinit();
        self.init(w, h);
    }

    pub fn handleInput(self: *Effects) void {
        if (rl.isKeyPressed(rl.c.KEY_T)) self.trails_on = !self.trails_on;
        if (rl.isKeyPressed(rl.c.KEY_B)) self.bloom_on = !self.bloom_on;
    }

    pub fn anyActive(self: *const Effects) bool {
        return self.trails_on or self.bloom_on;
    }

    pub fn beginScene(self: *Effects) void {
        rl.c.BeginTextureMode(self.scene_tex);
        // Transparent when trails are on so previous frames show through.
        // Opaque BG when only bloom is active.
        if (self.trails_on) {
            rl.c.ClearBackground(rl.c.Color{ .r = 0, .g = 0, .b = 0, .a = 0 });
        } else {
            rl.c.ClearBackground(constants.BG_COLOR);
        }
    }

    pub fn endScene(self: *Effects) void {
        rl.c.EndTextureMode();

        const w: f32 = @floatFromInt(self.width);
        const h: f32 = @floatFromInt(self.height);

        if (self.trails_on) self.compositeTrails(w, h);
        if (self.bloom_on) self.compositeBloom(w, h);

        // Final blit to screen
        rl.c.BeginDrawing();
        rl.c.ClearBackground(rl.c.BLACK);

        if (self.trails_on) {
            const src = if (self.which) self.trail_a else self.trail_b;
            blitRT(src.texture, w, h, rl.c.WHITE);
        } else {
            blitRT(self.scene_tex.texture, w, h, rl.c.WHITE);
        }

        if (self.bloom_on) {
            rl.c.BeginBlendMode(rl.c.BLEND_ADDITIVE);
            blitRT(self.bloom_tex.texture, w, h, rl.c.WHITE);
            rl.c.EndBlendMode();
        }
    }

    fn compositeTrails(self: *Effects, w: f32, h: f32) void {
        const read_tex = if (self.which) self.trail_a.texture else self.trail_b.texture;
        const write_target = if (self.which) self.trail_b else self.trail_a;

        rl.c.BeginTextureMode(write_target);

        // Start with the background color
        rl.c.ClearBackground(constants.BG_COLOR);

        // Draw previous trail frame with fade (the persistence effect)
        const fade_alpha: u8 = @intFromFloat(self.trail_fade * 255.0);
        blitRT(read_tex, w, h, rl.color(255, 255, 255, fade_alpha));

        // Draw current scene on top (transparent background, only dots/glow/lines)
        rl.c.BeginBlendMode(rl.c.BLEND_ALPHA);
        blitRT(self.scene_tex.texture, w, h, rl.c.WHITE);
        rl.c.EndBlendMode();

        rl.c.EndTextureMode();
        self.which = !self.which;
    }

    fn compositeBloom(self: *Effects, w: f32, h: f32) void {
        const resolution = [2]f32{ w, h };
        rl.c.SetShaderValue(self.blur_shader, self.blur_res_loc, &resolution, rl.c.SHADER_UNIFORM_VEC2);

        const source = if (self.trails_on)
            (if (self.which) self.trail_a.texture else self.trail_b.texture)
        else
            self.scene_tex.texture;

        // Pass 1: horizontal blur → scratch_tex
        const dir_h = [2]f32{ 1.0, 0.0 };
        rl.c.SetShaderValue(self.blur_shader, self.blur_dir_loc, &dir_h, rl.c.SHADER_UNIFORM_VEC2);
        rl.c.BeginTextureMode(self.scratch_tex);
        rl.c.ClearBackground(rl.c.BLACK);
        rl.c.BeginShaderMode(self.blur_shader);
        blitRT(source, w, h, rl.c.WHITE);
        rl.c.EndShaderMode();
        rl.c.EndTextureMode();

        // Pass 2: vertical blur → bloom_tex
        const dir_v = [2]f32{ 0.0, 1.0 };
        rl.c.SetShaderValue(self.blur_shader, self.blur_dir_loc, &dir_v, rl.c.SHADER_UNIFORM_VEC2);
        rl.c.BeginTextureMode(self.bloom_tex);
        rl.c.ClearBackground(rl.c.BLACK);
        rl.c.BeginShaderMode(self.blur_shader);
        blitRT(self.scratch_tex.texture, w, h, rl.c.WHITE);
        rl.c.EndShaderMode();
        rl.c.EndTextureMode();
    }
};

/// Blit a render texture. Always flips Y because OpenGL render textures
/// store data bottom-up, but Raylib's DrawTexturePro reads top-down.
/// Works for both drawing to screen AND drawing into another render texture
/// (BeginTextureMode internally handles the destination coordinate system).
fn blitRT(tex: rl.c.Texture2D, w: f32, h: f32, tint: rl.c.Color) void {
    const src = rl.c.Rectangle{ .x = 0, .y = 0, .width = w, .height = -h };
    const dst = rl.c.Rectangle{ .x = 0, .y = 0, .width = w, .height = h };
    rl.c.DrawTexturePro(tex, src, dst, rl.c.Vector2{ .x = 0, .y = 0 }, 0, tint);
}

const blur_fs: [*:0]const u8 =
    \\#version 330
    \\in vec2 fragTexCoord;
    \\in vec4 fragColor;
    \\uniform sampler2D texture0;
    \\uniform vec2 resolution;
    \\uniform vec2 direction;
    \\out vec4 finalColor;
    \\
    \\void main() {
    \\    vec2 texel = 1.0 / resolution;
    \\
    \\    // 13-tap Gaussian via bilinear trick (7 fetches)
    \\    float w0 = 0.1964825501511404;
    \\    float w1 = 0.2969069646728344;
    \\    float w2 = 0.09447039785044732;
    \\    float w3 = 0.010381362401148057;
    \\    float o1 = 1.411764705882353;
    \\    float o2 = 3.2941176470588234;
    \\    float o3 = 5.176470588235294;
    \\
    \\    vec2 step = direction * texel * 2.0;
    \\
    \\    vec3 result = texture(texture0, fragTexCoord).rgb * w0;
    \\    result += texture(texture0, fragTexCoord + step * o1).rgb * w1;
    \\    result += texture(texture0, fragTexCoord - step * o1).rgb * w1;
    \\    result += texture(texture0, fragTexCoord + step * o2).rgb * w2;
    \\    result += texture(texture0, fragTexCoord - step * o2).rgb * w2;
    \\    result += texture(texture0, fragTexCoord + step * o3).rgb * w3;
    \\    result += texture(texture0, fragTexCoord - step * o3).rgb * w3;
    \\
    \\    finalColor = vec4(result, 1.0);
    \\}
;
