//! The console leaf's tool strip (RA8EMU-1122): one text row across the
//! top of the leaf with the save tab at its right end, the log under it.
//! The tab reads SAVE, then SAVED or FAILED after a save.
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const widget = @import("ra8_widget");
const console_pane = @import("console_pane.zig");
const console_save = @import("../console/save.zig");
const Theme = @import("colors.zig").Theme;

const Rect = draw_list.Rect;

/// The strip: one text row with the pane's pad above and below.
pub const strip_h: i32 = @as(i32, @intCast(font.cell_h)) + 2 * console_pane.pad;
/// The save tab: the widest label with the pane's pad either side.
pub const tab_w: i32 = @as(i32, @intCast(font.textWidth(console_save.label_len))) + 2 * console_pane.pad;

/// The strip across the top of `area`; no height when `area` is shorter.
pub fn strip(area: Rect) Rect {
    const h: i32 = if (area.h >= strip_h) strip_h else 0;
    return .{ .x = area.x, .y = area.y, .w = area.w, .h = h };
}

/// The save tab at the strip's right end; empty when the strip is too
/// short or too narrow to hold it.
pub fn saveTab(area: Rect) Rect {
    const row = strip(area);
    const w: i32 = if (row.h > 0 and row.w >= tab_w) tab_w else 0;
    return .{ .x = row.x + row.w - w, .y = row.y, .w = w, .h = if (w > 0) row.h else 0 };
}

/// What is left of `area` under the strip, for the log.
pub fn below(area: Rect) Rect {
    const top = strip(area).h;
    return .{ .x = area.x, .y = area.y + top, .w = area.w, .h = area.h - top };
}

pub fn draw(table: *const widget.types.Paint, theme: *const Theme, area: Rect, outcome: console_save.Outcome) void {
    const row = strip(area);
    if (row.h == 0) return;
    fillArea(table, row, theme.face);
    const tab = saveTab(area);
    if (tab.w == 0) return;
    fillArea(table, tab, theme.button_face);
    const ink = if (outcome == .failed) theme.bad else theme.ink;
    drawText(table, tab.x + console_pane.pad, tab.y + console_pane.pad, outcome.label(), ink, theme.button_face);
}

fn fillArea(table: *const widget.types.Paint, r: Rect, color: draw_list.Color) void {
    table.fill_rect.?(table.user, r.x, r.y, r.w, r.h, word(color));
}

/// `text` drawn at (x, y) through the shared Paint table; `bg` is the fill
/// already under the text's cell, so pixels stay identical.
fn drawText(table: *const widget.types.Paint, x: i32, y: i32, text: []const u8, fg: draw_list.Color, bg: draw_list.Color) void {
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
fn word(color: draw_list.Color) u32 {
    return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
}
