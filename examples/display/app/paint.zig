//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! Binds ra8_widget's CPU canvas into a paint struct. Host goldens and the
//! board image draw through this same binding into an 8-bit greyscale
//! buffer, so a frame captured from the emulator can be compared with a host
//! render pixel for pixel.

const rw = @import("ra8_widget");
const cpu = @import("canvas");
const theme = @import("theme.zig");

pub const Canvas = cpu.Canvas;
pub const Paint = rw.types.Paint;

const ui_face: u8 = @backingInt(theme.Face.sans);
const ui_weight: u8 = @backingInt(theme.Weight.regular);
const ui_size: u8 = @backingInt(theme.text.ui_size);

/// A widget's own text (rows, tabs, pager, buttons) goes through the
/// unstyled callbacks. They are bound to the theme's UI size here.
fn drawUiText(user: ?*anyopaque, x: i32, y: i32, str: [*:0]const u8, fg: u32, bg: u32) callconv(.c) void {
    Canvas.drawTextStyle(user, x, y, str, ui_face, ui_weight, ui_size, fg, bg);
}

fn uiTextSize(user: ?*anyopaque, str: [*:0]const u8, out_w: *i32, out_h: *i32) callconv(.c) void {
    Canvas.textSizeStyle(user, str, ui_face, ui_weight, ui_size, out_w, out_h);
}

/// The paint struct every widget on `canvas` draws through.
pub fn bind(canvas: *Canvas) Paint {
    return .{
        .user = canvas,
        .fill_rect = Canvas.fillRect,
        .draw_text = drawUiText,
        .text_size = uiTextSize,
        .draw_text_face = Canvas.drawTextFace,
        .text_size_face = Canvas.textSizeFace,
        .draw_text_style = Canvas.drawTextStyle,
        .text_size_style = Canvas.textSizeStyle,
    };
}

/// Pixel width of `str` in a text style, for wrapping and fitting.
pub fn measure(str: [*:0]const u8, style: theme.Text) i32 {
    var w: i32 = 0;
    var h: i32 = 0;
    Canvas.textSizeStyle(null, str, @backingInt(style.face), @backingInt(style.weight), @backingInt(style.size), &w, &h);
    return w;
}

/// Line height of a text style in pixels.
pub fn lineHeight(style: theme.Text) i32 {
    var w: i32 = 0;
    var h: i32 = 0;
    Canvas.textSizeStyle(null, "M", @backingInt(style.face), @backingInt(style.weight), @backingInt(style.size), &w, &h);
    return h;
}
