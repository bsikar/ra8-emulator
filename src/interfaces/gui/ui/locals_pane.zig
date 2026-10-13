//! The locals pane (RA8EMU-805): one row per local of the core's innermost
//! frame at the stopped pc, read with the image's .debug_info the way
//! `locals` is (session/dwarf/locals.zig). Each row is the local's name,
//! its type with the byte size, and where it lives: an offset from the
//! frame base, a register with an offset, a register on its own, or a
//! global address. The innermost row is amber.
//!
//! The session packs the list (src/interfaces/rpc/session/locals.zig) and
//! gui/shell/locals.zig copies names into the snapshot, so `draw` holds no
//! slice into the link's buffer. The pane never imports the session.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const Theme = @import("colors.zig").Theme;
const widget_paint = @import("ra8_render").widget_paint;
const widget = @import("ra8_widget");

const Color = draw_list.Color;
const Rect = draw_list.Rect;

pub const pad: i32 = 4;
pub const row_h: i32 = @as(i32, @intCast(font.cell_h)) + 4;
/// The most locals a `locals` walk returns; gui/shell/locals.zig checks it
/// against the wire's limit at comptime.
pub const max_rows: usize = 32;
/// Characters a local's name and its type's name keep.
pub const name_cap: usize = 40;
pub const type_cap: usize = 40;
/// Keep the stored names intact while fitting the four columns in a shell leaf.
pub const display_name_cap: usize = 20;
pub const display_type_cap: usize = 20;
/// Character columns: the name, the type, the size, the where.
pub const name_at: usize = 2;
pub const type_at: usize = name_at + display_name_cap + 2;
pub const size_at: usize = type_at + display_type_cap + 2;
pub const where_at: usize = size_at + 8;
/// The narrowest pane: the columns before the where and room for 12 more.
pub const min_w: i32 = 2 * pad + 2 + @as(i32, @intCast(font.textWidth(where_at + 12)));

pub const Row = struct {
    name_buf: [name_cap]u8 = undefined,
    name_len: usize = 0,
    type_buf: [type_cap]u8 = undefined,
    type_len: usize = 0,
    /// The type's byte size; 0 when the DIE carries none.
    size: u64 = 0,
    /// The where kinds the wire packs: frame, register, in_register, address.
    where_kind: u8 = 0,
    where_a: i64 = 0,
    where_b: i64 = 0,

    pub fn name(self: *const Row) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn type_name(self: *const Row) []const u8 {
        return self.type_buf[0..self.type_len];
    }
};

pub const Snapshot = struct {
    count: usize = 0,
    rows: [max_rows]Row = @splat(.{}),
};

/// How many rows fit down `area`.
pub fn rows(area: Rect) usize {
    const inner = area.h - 2 * pad;
    if (inner < row_h) return 0;
    return @intCast(@divTrunc(inner, row_h));
}

/// Row `row`'s full-width band.
pub fn rowRect(area: Rect, row: usize) Rect {
    return .{ .x = area.x, .y = area.y + pad + @as(i32, @intCast(row)) * row_h, .w = area.w, .h = row_h };
}

/// Draw the pane through the shared Paint table (RA8EMU-1159): the
/// background fill dispatches through the table, and the text is the
/// firmware's label widget, so no pane code emits raw glyph commands.
pub fn draw(list: *draw_list.DrawList, theme: *const Theme, area: Rect, snapshot: *const Snapshot) !void {
    if (area.w < min_w or rows(area) == 0) return;
    try list.pushClip(area);
    defer list.popClip();
    var target = widget_paint.Target{ .list = list };
    const paint = target.paint();
    fillArea(&paint, area, word(theme.background));
    for (0..@min(rows(area), snapshot.count)) |row| drawRow(&paint, theme, area, row, &snapshot.rows[row]);
}

fn drawRow(table: *const widget.types.Paint, theme: *const Theme, area: Rect, row: usize, local: *const Row) void {
    const x = area.x + pad + 2;
    const y = rowRect(area, row).y + 2;
    const bg = word(theme.background);
    const lead = if (row == 0) theme.highlight else theme.muted;
    const name = local.name();
    const type_name = local.type_name();
    drawText(table, x, y, name[0..@min(name.len, display_name_cap)], word(if (local.name_len == 0) theme.muted else if (row == 0) theme.highlight else theme.ink), bg);
    drawText(table, x + column(type_at), y, type_name[0..@min(type_name.len, display_type_cap)], word(theme.ink), bg);
    var size: [14]u8 = undefined;
    const size_text = std.fmt.bufPrint(&size, "{d} B", .{local.size}) catch return;
    drawText(table, x + column(size_at), y, size_text, word(lead), bg);
    var where: [22]u8 = undefined;
    const where_text = whereLabel(&where, local) catch return;
    drawText(table, x + column(where_at), y, where_text, word(theme.muted), bg);
}

/// The wire's where kinds, one word: frame, register with offset, a
/// register, a global address, or an empty cell for none.
pub fn whereLabel(buffer: []u8, local: *const Row) ![]const u8 {
    return switch (local.where_kind) {
        1 => std.fmt.bufPrint(buffer, "fb{d}", .{local.where_a}),
        2 => if (local.where_b == 0) std.fmt.bufPrint(buffer, "r{d}", .{local.where_a}) else std.fmt.bufPrint(buffer, "r{d}{c}{d}", .{ local.where_a, @as(u8, if (local.where_b < 0) '-' else '+'), @abs(local.where_b) }),
        3 => std.fmt.bufPrint(buffer, "r{d}", .{local.where_a}),
        4 => std.fmt.bufPrint(buffer, "@0x{X:0>8}", .{@as(u64, @bitCast(local.where_a))}),
        else => std.fmt.bufPrint(buffer, "", .{}),
    };
}

fn column(chars: usize) i32 {
    return @intCast(font.textWidth(chars));
}

/// `area` filled with `color` through the shared Paint table.
fn fillArea(table: *const widget.types.Paint, area: Rect, color: u32) void {
    table.fill_rect.?(table.user, area.x, area.y, area.w, area.h, color);
}

/// `color` as the widget's 0x00RRGGBB colour word.
fn word(color: Color) u32 {
    return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
}

/// One line of text as the firmware's label widget (RA8EMU-1159): the label
/// owns the face and the aligned rendering; the rect is this line's cell.
fn drawText(table: *const widget.types.Paint, x: i32, y: i32, text: []const u8, fg: u32, bg: u32) void {
    var buffer: [128]u8 = undefined;
    const n = @min(text.len, buffer.len - 1);
    @memcpy(buffer[0..n], text[0..n]);
    buffer[n] = 0;
    var descriptor = widget.label.Label{
        .paint = table,
        .text = buffer[0..n :0].ptr,
        .fg = fg,
        .bg = bg,
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
