//! The status strip (RA8EMU-759): the status bar's line painted along the
//! bottom of the shell window. A dot at the left carries the state's tone
//! (connected, failed, running, halted); the text is cut to whole cells when
//! the window is narrow, never drawn past the strip. gui/status_capture.zig
//! reads the session's status into a `Strip`; this file never imports it.
const draw_list = @import("../../../render/draw_list.zig");
const font = @import("../../../render/font.zig");

const Color = draw_list.Color;
const Rect = draw_list.Rect;

pub const background = Color.rgb(0x21, 0x25, 0x2B);
pub const border = Color.rgb(0x4A, 0x51, 0x5C);
pub const ink = Color.rgb(0xD8, 0xDE, 0xE9);
pub const pad: i32 = 4;
pub const dot: i32 = 6;
/// One text line with two pixels of air above and below, plus the border.
pub const height: i32 = @as(i32, @intCast(font.cell_h)) + 5;

pub const Tone = enum {
    waiting,
    good,
    bad,
    running,
    halted,

    pub fn color(self: Tone) Color {
        return switch (self) {
            .waiting => Color.rgb(0x9A, 0xA5, 0xB4),
            .good => Color.rgb(0x98, 0xC3, 0x79),
            .bad => Color.rgb(0xE0, 0x6C, 0x75),
            .running => Color.rgb(0x61, 0xAF, 0xEF),
            .halted => Color.rgb(0xE5, 0xC0, 0x7B),
        };
    }
};

/// What one frame of the strip shows: the dot's tone and the status line.
pub const Strip = struct {
    tone: Tone = .waiting,
    line_buf: [256]u8 = undefined,
    line_len: usize = 0,

    pub fn line(self: *const Strip) []const u8 {
        return self.line_buf[0..self.line_len];
    }
};

/// The strip's place in a window of `width` by `window_h` pixels.
pub fn area(width: i32, window_h: i32) Rect {
    return .{ .x = 0, .y = window_h - height, .w = width, .h = height };
}

pub fn draw(list: *draw_list.DrawList, strip: Rect, view: *const Strip) !void {
    if (strip.empty()) return;
    try list.fill(strip, background);
    try list.fill(.{ .x = strip.x, .y = strip.y, .w = strip.w, .h = 1 }, border);
    try list.pushClip(strip);
    defer list.popClip();
    const middle = strip.y + 1 + @divTrunc(strip.h - 1 - dot, 2);
    try list.fill(.{ .x = strip.x + pad, .y = middle, .w = dot, .h = dot }, view.tone.color());
    const line = view.line();
    const left = strip.x + pad + dot + pad;
    const room = strip.x + strip.w - pad - left;
    if (room <= 0) return;
    const shown = font.fit(line, @intCast(room));
    const top = strip.y + 1 + @divTrunc(strip.h - 1 - @as(i32, font.glyph_h), 2);
    try font.draw(list, left, top, shown, ink);
}
