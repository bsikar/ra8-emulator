//! The fork confirmation banner (Slice 20.4): warns the user of a pending
//! intervention in past history and provides Confirm and Cancel controls.
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const widget = @import("ra8_widget");
const Theme = @import("colors.zig").Theme;

const Color = draw_list.Color;
const Rect = draw_list.Rect;

pub const pad: i32 = 6;
pub const btn_w: i32 = 64;
pub const height: i32 = @as(i32, @intCast(font.cell_h)) + 8;

pub const Action = enum { none, confirm, cancel };

pub fn buttonConfirm(banner: Rect) Rect {
    const y = banner.y + 3;
    const h = banner.h - 6;
    const x = banner.x + banner.w - pad - btn_w;
    return .{ .x = x, .y = y, .w = btn_w, .h = h };
}

pub fn buttonCancel(banner: Rect) Rect {
    const y = banner.y + 3;
    const h = banner.h - 6;
    const x = banner.x + banner.w - 2 * pad - 2 * btn_w;
    return .{ .x = x, .y = y, .w = btn_w, .h = h };
}

pub fn hit(banner: Rect, x: i32, y: i32) Action {
    if (banner.empty()) return .none;
    if (buttonConfirm(banner).contains(x, y)) return .confirm;
    if (buttonCancel(banner).contains(x, y)) return .cancel;
    return .none;
}

pub fn draw(table: *const widget.types.Paint, theme: *const Theme, banner: Rect) void {
    if (banner.empty()) return;
    fillArea(table, banner, theme.surface);
    fillArea(table, .{ .x = banner.x, .y = banner.y + banner.h - 1, .w = banner.w, .h = 1 }, theme.border);

    const msg = "Fork pending: action in past history. Confirm branch?";
    const text_top = banner.y + draw_list.centre(banner.h, font.glyph_h);
    drawText(table, banner.x + pad, text_top, msg, theme.ink, theme.surface);

    // Cancel button
    const c_btn = buttonCancel(banner);
    fillArea(table, c_btn, theme.well);
    drawBorder(table, c_btn, theme.border);
    const c_top = c_btn.y + draw_list.centre(c_btn.h, font.glyph_h);
    drawText(table, c_btn.x + 8, c_top, "Cancel", theme.ink, theme.well);

    // Confirm button
    const ok_btn = buttonConfirm(banner);
    fillArea(table, ok_btn, theme.well);
    drawBorder(table, ok_btn, theme.border);
    const ok_top = ok_btn.y + draw_list.centre(ok_btn.h, font.glyph_h);
    drawText(table, ok_btn.x + 8, ok_top, "Confirm", theme.ink, theme.well);
}

fn fillArea(table: *const widget.types.Paint, r: Rect, color: Color) void {
    table.fill_rect.?(table.user, r.x, r.y, r.w, r.h, word(color));
}

fn drawBorder(table: *const widget.types.Paint, r: Rect, color: Color) void {
    fillArea(table, .{ .x = r.x, .y = r.y, .w = r.w, .h = 1 }, color);
    fillArea(table, .{ .x = r.x, .y = r.y + r.h - 1, .w = r.w, .h = 1 }, color);
    fillArea(table, .{ .x = r.x, .y = r.y, .w = 1, .h = r.h }, color);
    fillArea(table, .{ .x = r.x + r.w - 1, .y = r.y, .w = 1, .h = r.h }, color);
}

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

fn word(color: Color) u32 {
    return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
}
