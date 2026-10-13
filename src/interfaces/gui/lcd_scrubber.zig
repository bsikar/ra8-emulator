//! The LCD pane's scrubber strip (RA8EMU-825, piece 4 of 5 under
//! RA8EMU-205): one cell per frame of the history ring across a row, the
//! selected frame's cell lit, the selected frame's virtual timestamp
//! labelled at the right end, and the label switching to "live" while the
//! pane follows the feed. Paint only: the ring model lives in
//! lcd_history.zig, and the strip draws whatever count and selection a
//! caller hands it, so the pane never needs the ring to paint.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const widget = @import("ra8_widget");
const Theme = @import("ui/colors.zig").Theme;

const Rect = draw_list.Rect;

/// One frame cell's width, the gap between cells, and the cells row's height.
pub const cell_w: i32 = 8;
pub const cell_gap: i32 = 2;
pub const cells_h: i32 = 10;
pub const pad: i32 = 4;

/// The strip's full height: pad, cells row, gap, label row, pad.
pub const strip_h: i32 = pad + cells_h + 2 + @as(i32, @intCast(font.cell_h)) + pad;

/// The strip across the bottom of `area`; no height when `area` is shorter.
pub fn strip(area: Rect) Rect {
    const h: i32 = if (area.h >= strip_h) strip_h else 0;
    return .{ .x = area.x, .y = area.y + area.h - h, .w = area.w, .h = h };
}

/// How many frames the strip can show across `area`'s width.
pub fn fits(area: Rect) usize {
    const row_w = area.w - 2 * pad;
    if (row_w < cell_w) return 0;
    return @intCast(@divTrunc(row_w + cell_gap, cell_w + cell_gap));
}

/// What the strip paints for one frame set: the frame count, the selected
/// index (null while the pane follows the feed), and the selected frame's
/// virtual timestamp.
pub const View = struct {
    count: usize,
    selected: ?usize = null,
    stamp: u64 = 0,
};

/// The strip's label: the selected frame's stamp, or live.
pub fn label(view: View, into: []u8) []const u8 {
    const sel = view.selected orelse return "live";
    if (sel >= view.count) return "live";
    return std.fmt.bufPrint(into, "t={d}ns", .{view.stamp}) catch "live";
}

pub fn draw(table: *const widget.types.Paint, theme: *const Theme, area: Rect, view: View) void {
    const row = strip(area);
    if (row.h == 0) return;
    fillArea(table, row, theme.face);

    // The newest frames that fit, left to right; earlier frames sit in the
    // same cells the eviction already forgot, so the strip stays honest.
    const shown = @min(view.count, fits(area));
    const first = view.count - shown;
    const cells_y = row.y + pad;
    var index: usize = first;
    while (index < view.count) : (index += 1) {
        const x = row.x + pad + @as(i32, @intCast(index - first)) * (cell_w + cell_gap);
        const on = view.selected != null and view.selected.? == index;
        fillArea(table, .{ .x = x, .y = cells_y, .w = cell_w, .h = cells_h }, if (on) theme.accent else theme.control_border);
    }

    var buf: [32]u8 = undefined;
    const text = label(view, &buf);
    const w: i32 = @intCast(font.textWidth(text.len));
    const live = view.selected == null;
    const text_y = cells_y + cells_h + 2;
    drawText(table, row.x + row.w - w - pad, text_y, text, if (live) theme.muted else theme.ink, theme.face);
}

fn fillArea(table: *const widget.types.Paint, r: Rect, color: draw_list.Color) void {
    table.fill_rect.?(table.user, r.x, r.y, r.w, r.h, word(color));
}

/// `text` drawn at (x, y) through the shared Paint table; `bg` is the fill
/// already under the text's cell, so pixels stay identical.
fn drawText(table: *const widget.types.Paint, x: i32, y: i32, text: []const u8, fg: draw_list.Color, bg: draw_list.Color) void {
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
fn word(color: draw_list.Color) u32 {
    return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
}
