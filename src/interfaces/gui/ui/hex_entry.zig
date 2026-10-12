//! A small hex-entry field (RA8EMU-742), shared by the registers and memory
//! panes: type hex digits over a value, Enter commits, Escape cancels.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const widget = @import("ra8_widget");
const Theme = @import("colors.zig").Theme;

const Color = draw_list.Color;
const Rect = draw_list.Rect;

pub const max_digits: usize = 8;

pub const codes = struct {
    pub const enter: u32 = 0x0D;
    pub const escape: u32 = 0x1B;
    pub const backspace: u32 = 0x08;
    pub const delete: u32 = 0x7F;
};

pub const Outcome = union(enum) {
    typing,
    commit: u32,
    cancel,
};

pub const Field = struct {
    /// How many digits the value has: 8 for a register, 2 for a byte.
    width: usize,
    digits: [max_digits]u8 = undefined,
    len: usize = 0,

    pub fn init(width: usize) Field {
        return .{ .width = @min(width, max_digits) };
    }

    pub fn text(self: *const Field) []const u8 {
        return self.digits[0..self.len];
    }

    /// Appends the hex digits of `typed`, upper-cased, up to the width.
    pub fn typed(self: *Field, input: []const u8) void {
        for (input) |byte| {
            if (self.len == self.width) return;
            if (!std.ascii.isHex(byte)) continue;
            self.digits[self.len] = std.ascii.toUpper(byte);
            self.len += 1;
        }
    }

    /// Enter commits what was typed (cancels when nothing was), Escape
    /// cancels, Backspace drops a digit; any other key keeps typing.
    pub fn key(self: *Field, code: u32) Outcome {
        switch (code) {
            codes.enter => {
                if (self.len == 0) return .cancel;
                return .{ .commit = std.fmt.parseInt(u32, self.text(), 16) catch unreachable };
            },
            codes.escape => return .cancel,
            codes.backspace, codes.delete => self.len -|= 1,
            else => {},
        }
        return .typing;
    }
};

/// The band the field covers when its text starts at (x, y).
pub fn bandRect(x: i32, y: i32, field: *const Field) Rect {
    return .{ .x = x - 1, .y = y - 1, .w = @as(i32, @intCast(font.textWidth(field.width))) + 2, .h = @as(i32, @intCast(font.cell_h)) + 2 };
}

/// The caret after the typed digits.
pub fn caretRect(x: i32, y: i32, field: *const Field) Rect {
    return .{ .x = x + @as(i32, @intCast(font.textWidth(field.len))), .y = y, .w = 1, .h = @intCast(font.cell_h) };
}

/// `area` filled with `color` through the shared Paint table.
pub fn fillArea(table: *const widget.types.Paint, area: Rect, color: Color) void {
    table.fill_rect.?(table.user, area.x, area.y, area.w, area.h, word(color));
}

/// `text` drawn at (x, y) through the shared Paint table; `bg` is the fill
/// already under the text's cell.
pub fn drawText(table: *const widget.types.Paint, x: i32, y: i32, text: []const u8, fg: Color, bg: Color) void {
    var buffer: [64]u8 = undefined;
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
pub fn word(color: Color) u32 {
    return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
}

/// Draws the field over a value whose text starts at (x, y).
pub fn draw(table: *const widget.types.Paint, theme: *const Theme, x: i32, y: i32, field: *const Field) void {
    fillArea(table, bandRect(x, y, field), theme.band);
    drawText(table, x, y, field.text(), theme.highlight, theme.band);
    fillArea(table, caretRect(x, y, field), theme.ink);
}
