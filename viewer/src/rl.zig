// Thin wrapper around raylib C API via @cImport
pub const c = @cImport({
    @cInclude("raylib.h");
});

// Re-export commonly used types and helpers
pub const Vector2 = c.Vector2;
pub const Color = c.Color;
pub const Camera2D = c.Camera2D;
pub const Font = c.Font;
pub const Rectangle = c.Rectangle;

// Colors
pub fn color(r: u8, g: u8, b: u8, a: u8) Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

pub fn colorAlpha(col: Color, a: u8) Color {
    return .{ .r = col.r, .g = col.g, .b = col.b, .a = a };
}

pub fn colorFade(col: Color, alpha: f32) Color {
    const a_f = @as(f32, @floatFromInt(col.a)) * alpha;
    const a: u8 = @intFromFloat(@max(0.0, @min(255.0, a_f)));
    return .{ .r = col.r, .g = col.g, .b = col.b, .a = a };
}

// Vector helpers
pub fn vec2(x: f32, y: f32) Vector2 {
    return .{ .x = x, .y = y };
}

// Window
pub fn setConfigFlags(flags: c_uint) void {
    c.SetConfigFlags(flags);
}
pub fn initWindow(w: c_int, h: c_int, title: [*:0]const u8) void {
    c.InitWindow(w, h, title);
}
pub fn closeWindow() void {
    c.CloseWindow();
}
pub fn windowShouldClose() bool {
    return c.WindowShouldClose();
}
pub fn setTargetFPS(fps: c_int) void {
    c.SetTargetFPS(fps);
}
pub fn getFrameTime() f32 {
    return c.GetFrameTime();
}
pub fn toggleFullscreen() void {
    c.ToggleBorderlessWindowed();
}
pub fn getScreenWidth() c_int {
    return c.GetScreenWidth();
}
pub fn getScreenHeight() c_int {
    return c.GetScreenHeight();
}
pub fn getMonitorWidth(monitor: c_int) c_int {
    return c.GetMonitorWidth(monitor);
}
pub fn getMonitorHeight(monitor: c_int) c_int {
    return c.GetMonitorHeight(monitor);
}

pub const FLAG_MSAA_4X_HINT = c.FLAG_MSAA_4X_HINT;
pub const FLAG_WINDOW_RESIZABLE = c.FLAG_WINDOW_RESIZABLE;
pub const FLAG_VSYNC_HINT = c.FLAG_VSYNC_HINT;
pub const KEY_F11 = c.KEY_F11;
pub const KEY_F = c.KEY_F;

// Drawing
pub fn beginDrawing() void {
    c.BeginDrawing();
}
pub fn endDrawing() void {
    c.EndDrawing();
}
pub fn clearBackground(col: Color) void {
    c.ClearBackground(col);
}
pub fn beginMode2D(cam: Camera2D) void {
    c.BeginMode2D(cam);
}
pub fn endMode2D() void {
    c.EndMode2D();
}

// Shapes
pub fn drawLineV(start: Vector2, end: Vector2, col: Color) void {
    c.DrawLineV(start, end, col);
}
pub fn drawLineEx(start: Vector2, end: Vector2, thick: f32, col: Color) void {
    c.DrawLineEx(start, end, thick, col);
}
pub fn drawCircleV(center: Vector2, radius: f32, col: Color) void {
    c.DrawCircleV(center, radius, col);
}
pub fn drawCircleLinesV(center: Vector2, radius: f32, col: Color) void {
    c.DrawCircleLinesV(center, radius, col);
}
pub fn drawTriangle(v1: Vector2, v2: Vector2, v3: Vector2, col: Color) void {
    c.DrawTriangle(v1, v2, v3, col);
}
pub fn drawRectangle(x: c_int, y: c_int, w: c_int, h: c_int, col: Color) void {
    c.DrawRectangle(x, y, w, h, col);
}
pub fn drawRectangleRounded(rec: Rectangle, roundness: f32, segments: c_int, col: Color) void {
    c.DrawRectangleRounded(rec, roundness, segments, col);
}
pub fn drawRectangleRoundedLines(rec: Rectangle, roundness: f32, segments: c_int, col: Color) void {
    c.DrawRectangleRoundedLinesEx(rec, roundness, segments, 1.0, col);
}

// Text
pub fn drawTextEx(font: Font, text: [*:0]const u8, pos: Vector2, fontSize: f32, spacing: f32, tint: Color) void {
    c.DrawTextEx(font, text, pos, fontSize, spacing, tint);
}
pub fn drawFPS(x: c_int, y: c_int) void {
    c.DrawFPS(x, y);
}
pub fn getFontDefault() Font {
    return c.GetFontDefault();
}

// Input
pub fn getMousePosition() Vector2 {
    return c.GetMousePosition();
}
pub fn getMouseWheelMove() f32 {
    return c.GetMouseWheelMove();
}
pub fn isMouseButtonPressed(button: c_int) bool {
    return c.IsMouseButtonPressed(button);
}
pub fn isMouseButtonDown(button: c_int) bool {
    return c.IsMouseButtonDown(button);
}
pub fn isMouseButtonReleased(button: c_int) bool {
    return c.IsMouseButtonReleased(button);
}
pub fn isKeyPressed(key: c_int) bool {
    return c.IsKeyPressed(key);
}
pub fn getCharPressed() c_int {
    return c.GetCharPressed();
}

// Camera
pub fn getScreenToWorld2D(pos: Vector2, cam: Camera2D) Vector2 {
    return c.GetScreenToWorld2D(pos, cam);
}
pub fn getWorldToScreen2D(pos: Vector2, cam: Camera2D) Vector2 {
    return c.GetWorldToScreen2D(pos, cam);
}

// Mouse buttons
pub const MOUSE_BUTTON_LEFT = c.MOUSE_BUTTON_LEFT;
pub const MOUSE_BUTTON_RIGHT = c.MOUSE_BUTTON_RIGHT;

// Keys
pub const KEY_SPACE = c.KEY_SPACE;
pub const KEY_ESCAPE = c.KEY_ESCAPE;
pub const KEY_HOME = c.KEY_HOME;
pub const KEY_END = c.KEY_END;
pub const KEY_LEFT = c.KEY_LEFT;
pub const KEY_RIGHT = c.KEY_RIGHT;
pub const KEY_LEFT_BRACKET = c.KEY_LEFT_BRACKET;
pub const KEY_RIGHT_BRACKET = c.KEY_RIGHT_BRACKET;
pub const KEY_SLASH = c.KEY_SLASH;
pub const KEY_BACKSPACE = c.KEY_BACKSPACE;
pub const KEY_ONE = c.KEY_ONE;
pub const KEY_TWO = c.KEY_TWO;
pub const KEY_THREE = c.KEY_THREE;
pub const KEY_FOUR = c.KEY_FOUR;
pub const KEY_FIVE = c.KEY_FIVE;
pub const KEY_SIX = c.KEY_SIX;
pub const KEY_SEVEN = c.KEY_SEVEN;
pub const KEY_EIGHT = c.KEY_EIGHT;
pub const KEY_E = c.KEY_E;
pub const KEY_G = c.KEY_G;
pub const KEY_N = c.KEY_N;
pub const KEY_T = c.KEY_T;
pub const KEY_B = c.KEY_B;
