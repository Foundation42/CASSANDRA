const rl = @import("rl.zig");

pub const FADE_WINDOW: f32 = 12.0;
pub const NUM_CLUSTERS: u8 = 8;
pub const NUM_ATTRACTORS: usize = 10;
pub const ANCHOR_DIM: usize = 50;

pub const WINDOW_W: c_int = 1600;
pub const WINDOW_H: c_int = 900;
pub const TARGET_FPS: c_int = 60;

pub const BG_COLOR = rl.color(10, 10, 18, 255);
pub const GRID_COLOR = rl.color(30, 30, 45, 255);
pub const HUD_COLOR = rl.color(0, 255, 180, 255);
pub const HUD_DIM = rl.color(0, 255, 180, 120);
pub const LABEL_COLOR = rl.color(200, 200, 220, 255);
pub const SCRUBBER_BG = rl.color(20, 20, 35, 220);
pub const SCRUBBER_FG = rl.color(0, 255, 180, 200);
pub const SEARCH_BG = rl.color(15, 15, 25, 230);
pub const HIGHLIGHT_COLOR = rl.color(255, 255, 0, 255);
pub const PHYSICS_COLOR = rl.color(255, 120, 50, 255);

pub const PALETTE = [8]rl.Color{
    rl.color(255, 77, 77, 255),
    rl.color(77, 166, 255, 255),
    rl.color(77, 255, 136, 255),
    rl.color(255, 200, 50, 255),
    rl.color(200, 100, 255, 255),
    rl.color(255, 150, 50, 255),
    rl.color(50, 255, 230, 255),
    rl.color(255, 120, 200, 255),
};

/// Wall-clock playback speeds: seconds of timeline per real second
pub const SPEED_LEVELS = [_]f32{ 10, 30, 60, 300, 600, 1800, 3600 };

/// Maximum keyframes kept in viewer memory. Oldest are dropped as new ones arrive.
pub const MAX_KEYFRAMES: u32 = 100;
