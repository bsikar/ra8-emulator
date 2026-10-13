//! The theme picker (RA8EMU-1165): one icon button at the right end of the
//! status strip showing the theme in use (a sun for Light, a moon for Dark, a
//! monitor for following the OS), and the popover that grows up out of it
//! when it is pressed, one row per theme with the one in use marked. The
//! button is a bordered chip, so it reads as a control on either palette,
//! and it keeps clear of the window's corner, which macOS rounds off. Open,
//! the chip and the popover share one outline, so the list reads as the icon
//! unfolded. This file lays out, paints and hit-tests; the shell's model
//! (shell/theme.zig) owns whether it is open and what a press does. The
//! icons are the GUI's own 16x16 glyphs, drawn as fills: no font and no
//! image carries them.
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const widget = @import("ra8_widget");
const colors = @import("colors.zig");

const Color = draw_list.Color;
const Rect = draw_list.Rect;
const Theme = colors.Theme;
const Choice = colors.Choice;

pub const pad: i32 = 4;
/// An icon is a square this many pixels a side.
pub const side: i32 = 16;
/// The chip the icon sits in: the icon inside one pixel of border.
pub const chip: i32 = side + 2;
/// Air between the chip and the window's right edge. macOS rounds a window's
/// bottom corners by about twenty points; a chip a point above the foot is
/// clear of that arc from eleven points in, and this leaves it room.
pub const margin: i32 = 14;
/// What the picker takes from the strip's right end.
pub const width: i32 = pad + chip + margin;
/// A popover row: an icon or a text line with two pixels of air above and below.
pub const row_h: i32 = side + 4;
/// The rows, top to bottom.
pub const rows = [_]Choice{ .light, .dark, .system };
/// The popover: its outline, an icon, the longest name and a pad around each.
pub const popover_w: i32 = 2 + 3 * pad + side + @as(i32, @intCast(font.textWidth(name(.system).len)));
/// The rows under one pixel of outline; the strip's top line closes it.
pub const popover_h: i32 = 1 + @as(i32, rows.len) * row_h;

pub fn name(choice: Choice) []const u8 {
    return switch (choice) {
        .light => "Light",
        .dark => "Dark",
        .system => "System",
    };
}

/// What the picker paints: the theme in use, and whether the popover is out.
pub const View = struct {
    choice: Choice = .dark,
    open: bool = false,
};

/// The strip's share left for the status line.
pub fn rest(strip: Rect) Rect {
    return .{ .x = strip.x, .y = strip.y, .w = strip.w - button(strip).w, .h = strip.h };
}

/// The picker's share of `strip`, a press anywhere in which is a press on
/// the button; empty when the strip is too narrow to hold it whole.
pub fn button(strip: Rect) Rect {
    const w = if (strip.w < width) 0 else width;
    return .{ .x = strip.x + strip.w - w, .y = strip.y, .w = w, .h = strip.h };
}

/// The chip the icon is drawn in, inside the button.
pub fn chipOf(strip: Rect) Rect {
    const at = button(strip);
    return .{ .x = at.x + pad, .y = at.y + 1 + @divFloor(at.h - 1 - chip, 2), .w = chip, .h = chip };
}

/// The popover's box, standing on `strip` with its right edge on the chip's.
pub fn popover(strip: Rect) Rect {
    const tab = chipOf(strip);
    return .{ .x = tab.x + tab.w - popover_w, .y = strip.y - popover_h, .w = popover_w, .h = popover_h };
}

/// Row `index` of the popover, inside its outline.
pub fn row(strip: Rect, index: usize) Rect {
    const box = popover(strip);
    return .{ .x = box.x + 1, .y = box.y + 1 + @as(i32, @intCast(index)) * row_h, .w = box.w - 2, .h = row_h };
}

pub const Hit = union(enum) { button, row: Choice };

/// What (`x`, `y`) lands on: the button, or a row while the popover is out.
pub fn hit(strip: Rect, open: bool, x: i32, y: i32) ?Hit {
    if (button(strip).contains(x, y)) return .button;
    if (!open) return null;
    for (rows, 0..) |choice, index| {
        if (row(strip, index).contains(x, y)) return .{ .row = choice };
    }
    return null;
}

pub fn draw(table: *const widget.types.Paint, theme: *const Theme, strip: Rect, view: View) void {
    const at = button(strip);
    if (at.empty()) return;
    fillArea(table, at, theme.well);
    fillArea(table, .{ .x = at.x, .y = at.y, .w = at.w, .h = 1 }, theme.border);
    const tab = chipOf(strip);
    // Open, the chip reaches up through the strip's top line to the popover.
    const stem: Rect = if (view.open) .{ .x = tab.x, .y = strip.y, .w = tab.w, .h = tab.y + tab.h - strip.y } else tab;
    fillArea(table, stem, theme.face);
    glyph(table, tab.x + 1, tab.y + 1, icon(view.choice), theme.ink);
    if (!view.open) return frame(table, theme.control_border, tab);
    const box = popover(strip);
    fillArea(table, box, theme.face);
    for (rows, 0..) |choice, index| drawRow(table, theme, row(strip, index), choice, choice == view.choice);
    outline(table, theme.control_border, box, stem);
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
fn word(color: draw_list.Color) u32 {
    return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
}

fn drawRow(table: *const widget.types.Paint, theme: *const Theme, area: Rect, choice: Choice, active: bool) void {
    if (active) fillArea(table, area, theme.band);
    const color = if (active) theme.highlight else theme.ink;
    glyph(table, area.x + pad, area.y + @divFloor(area.h - side, 2), icon(choice), color);
    const top = area.y + @divFloor(area.h - @as(i32, font.glyph_h), 2);
    // The band, when the row is marked, is the fill already under the text's
    // cell; the label paints its cell with it first.
    drawText(table, area.x + 2 * pad + side, top, name(choice), color, if (active) theme.band else theme.face);
}

/// One pixel of `color` round the inside of `area`.
fn frame(table: *const widget.types.Paint, color: Color, area: Rect) void {
    fillArea(table, .{ .x = area.x, .y = area.y, .w = area.w, .h = 1 }, color);
    fillArea(table, .{ .x = area.x, .y = area.y + area.h - 1, .w = area.w, .h = 1 }, color);
    fillArea(table, .{ .x = area.x, .y = area.y, .w = 1, .h = area.h }, color);
    fillArea(table, .{ .x = area.x + area.w - 1, .y = area.y, .w = 1, .h = area.h }, color);
}

/// One line around the popover and the chip under its right end: up the
/// popover's left, across its top, down the shared right edge to the foot of
/// the chip, back along the chip's foot and up its left to the popover.
fn outline(table: *const widget.types.Paint, color: Color, box: Rect, stem: Rect) void {
    const foot = stem.y + stem.h;
    fillArea(table, .{ .x = box.x, .y = box.y, .w = box.w, .h = 1 }, color);
    fillArea(table, .{ .x = box.x, .y = box.y, .w = 1, .h = box.h + 1 }, color);
    fillArea(table, .{ .x = box.x, .y = stem.y, .w = stem.x - box.x + 1, .h = 1 }, color);
    fillArea(table, .{ .x = box.x + box.w - 1, .y = box.y, .w = 1, .h = foot - box.y }, color);
    fillArea(table, .{ .x = stem.x, .y = stem.y, .w = 1, .h = stem.h }, color);
    fillArea(table, .{ .x = stem.x, .y = foot - 1, .w = stem.w, .h = 1 }, color);
}

/// An icon's rows, top to bottom; bit 15 is the leftmost pixel.
const Icon = [side]u16;

/// Adds `mask` with its top-left at (`x`, `y`), one fill per run of pixels.
fn glyph(table: *const widget.types.Paint, x: i32, y: i32, mask: *const Icon, color: Color) void {
    for (mask, 0..) |bits, line| {
        var column: i32 = 0;
        while (column < side) {
            if (!lit(bits, column)) {
                column += 1;
                continue;
            }
            const start = column;
            while (column < side and lit(bits, column)) column += 1;
            fillArea(table, .{ .x = x + start, .y = y + @as(i32, @intCast(line)), .w = column - start, .h = 1 }, color);
        }
    }
}

fn lit(bits: u16, column: i32) bool {
    return bits >> @intCast(side - 1 - column) & 1 != 0;
}

pub fn icon(choice: Choice) *const Icon {
    return switch (choice) {
        .light => &sun,
        .dark => &moon,
        .system => &monitor,
    };
}

fn bitmap(comptime art: [side][]const u8) Icon {
    var out: Icon = undefined;
    for (art, 0..) |line, index| {
        if (line.len != side) @compileError("an icon row is 16 pixels");
        var bits: u16 = 0;
        for (line) |char| bits = bits << 1 | @intFromBool(char == '#');
        out[index] = bits;
    }
    return out;
}

const sun = bitmap(.{
    "................",
    ".......##.......",
    ".......##.......",
    "..##........##..",
    "..##..####..##..",
    ".....######.....",
    "....########....",
    ".##.########.##.",
    ".##.########.##.",
    "....########....",
    ".....######.....",
    "..##..####..##..",
    "..##........##..",
    ".......##.......",
    ".......##.......",
    "................",
});

const moon = bitmap(.{
    "................",
    "................",
    "......##........",
    ".....###........",
    "....####........",
    "....####........",
    "...#####........",
    "...#####........",
    "...######.......",
    "...#######....#.",
    "....##########..",
    "....##########..",
    ".....########...",
    "......######....",
    "................",
    "................",
});

const monitor = bitmap(.{
    "................",
    "................",
    ".##############.",
    ".#............#.",
    ".#............#.",
    ".#............#.",
    ".#............#.",
    ".#............#.",
    ".#............#.",
    ".#............#.",
    ".##############.",
    ".......##.......",
    ".......##.......",
    "....########....",
    "................",
    "................",
});
