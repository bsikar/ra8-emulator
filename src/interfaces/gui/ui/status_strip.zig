//! The status strip (RA8EMU-759): the status bar's line painted along the
//! bottom of the shell window. A dot at the left carries the state's tone
//! (connected, failed, running, halted); the text is cut to whole cells when
//! the window is narrow, never drawn past the strip. src/interfaces/gui/status/capture.zig
//! reads the session's status into a `Strip`; this file never imports it.
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const widget = @import("ra8_widget");
const Theme = @import("colors.zig").Theme;

const Color = draw_list.Color;
const Rect = draw_list.Rect;

/// The strip sits in the well colour, below the panes' background.
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

    pub fn color(self: Tone, theme: *const Theme) Color {
        return switch (self) {
            .waiting => theme.tone().waiting,
            .good => theme.tone().good,
            .bad => theme.tone().bad,
            .running => theme.tone().running,
            .halted => theme.tone().halted,
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

pub fn draw(table: *const widget.types.Paint, theme: *const Theme, strip: Rect, view: *const Strip) void {
    if (strip.empty()) return;
    fillArea(table, strip, theme.well);
    fillArea(table, .{ .x = strip.x, .y = strip.y, .w = strip.w, .h = 1 }, theme.border);
    table.push_clip.?(table.user, strip.x, strip.y, strip.w, strip.h);
    defer table.pop_clip.?(table.user);
    const middle = strip.y + 1 + draw_list.centre(strip.h - 1, dot);
    // The dot sits on a pill a pixel wider all round.
    fillArea(table, .{ .x = strip.x + pad - 1, .y = middle - 1, .w = dot + 2, .h = dot + 2 }, theme.status_pill);
    fillArea(table, .{ .x = strip.x + pad, .y = middle, .w = dot, .h = dot }, view.tone.color(theme));
    const line = view.line();
    const left = strip.x + pad + dot + pad + 2;
    const room = strip.x + strip.w - pad - left;
    if (room <= 0) return;
    const shown = font.fit(line, @intCast(room));
    const top = strip.y + 1 + draw_list.centre(strip.h - 1, font.glyph_h);
    drawText(table, left, top, shown, theme.ink, theme.well);
}

fn fillArea(table: *const widget.types.Paint, r: Rect, color: Color) void {
    table.fill_rect.?(table.user, r.x, r.y, r.w, r.h, word(color));
}

/// `text` drawn at (x, y) through the shared Paint table; `bg` is the fill
/// already under the text's cell.
fn drawText(table: *const widget.types.Paint, x: i32, y: i32, text: []const u8, fg: Color, bg: Color) void {
    var buffer: [256]u8 = undefined;
    const n = @min(text.len, buffer.len - 1);
    @memcpy(buffer[0..n], text[0..n]);
    buffer[n] = 0;
    var descriptor = widget.label.Label{
        .paint = table,
        .text = buffer[0..n :0].ptr,
        .fg = word(fg),
        .bg = word(bg),
        .pad = 0,
        .alignment = .left,
        .face = .sans,
    };
    var w: widget.types.Widget = undefined;
    _ = widget.label.ra8_widget_label_init(&w, &descriptor);
    w.rect = .{
        .x = x,
        .y = y,
        .w = @intCast(font.textWidth(text.len)),
        .h = @intCast(font.cell_h),
    };
    w.vt.?.render.?(&w);
}

/// `color` as the widget's 0x00RRGGBB colour word.
fn word(color: Color) u32 {
    return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
}
