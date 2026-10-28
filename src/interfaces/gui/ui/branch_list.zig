//! Minimal branch list view (Slice 20.4): displays branches with switch
//! and delete-with-confirmation controls.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const widget = @import("ra8_widget");
const Theme = @import("colors.zig").Theme;

const Color = draw_list.Color;
const Rect = draw_list.Rect;

pub const pad: i32 = 4;
pub const row_h: i32 = @as(i32, @intCast(font.cell_h)) + 6;

pub const Item = struct {
    id: u32,
    parent: u32,
    fork_r: u64,
    end_r: u64,
    child_count: u32 = 0,
    is_live: bool = false,
    is_kept: bool = false,
    is_pinned: bool = false,
};

pub const Action = union(enum) {
    none,
    switch_branch: u32,
    request_delete: u32,
    confirm_delete: u32,
    cancel_delete,
};

pub fn hit(area: Rect, items: []const Item, confirming_id: ?u32, x: i32, y: i32) Action {
    if (area.empty() or !area.contains(x, y)) return .none;
    const header_h = row_h;
    var row_y = area.y + header_h;

    for (items) |it| {
        const r_box = Rect{ .x = area.x, .y = row_y, .w = area.w, .h = row_h };
        if (r_box.contains(x, y)) {
            if (it.is_live) return .none;
            const sw_btn = Rect{ .x = area.x + area.w - 140, .y = row_y + 2, .w = 50, .h = row_h - 4 };
            if (sw_btn.contains(x, y)) return .{ .switch_branch = it.id };

            if (confirming_id) |cid| {
                if (cid == it.id) {
                    const c_btn = Rect{ .x = area.x + area.w - 85, .y = row_y + 2, .w = 55, .h = row_h - 4 };
                    if (c_btn.contains(x, y)) return .{ .confirm_delete = it.id };
                    const x_btn = Rect{ .x = area.x + area.w - 25, .y = row_y + 2, .w = 20, .h = row_h - 4 };
                    if (x_btn.contains(x, y)) return .cancel_delete;
                }
            } else {
                const del_btn = Rect{ .x = area.x + area.w - 45, .y = row_y + 2, .w = 40, .h = row_h - 4 };
                if (del_btn.contains(x, y)) return .{ .request_delete = it.id };
            }
        }
        row_y += row_h;
    }
    return .none;
}

pub fn draw(table: *const widget.types.Paint, theme: *const Theme, area: Rect, items: []const Item, confirming_id: ?u32) void {
    if (area.empty()) return;
    fillArea(table, area, theme.surface);
    drawBorder(table, area, theme.border);

    // Header
    const title_y = area.y + draw_list.centre(row_h, font.glyph_h);
    drawText(table, area.x + pad, title_y, "Branches", theme.ink, theme.surface);
    fillArea(table, .{ .x = area.x, .y = area.y + row_h - 1, .w = area.w, .h = 1 }, theme.border);

    var row_y = area.y + row_h;
    for (items) |it| {
        if (row_y + row_h > area.y + area.h) break;
        if (it.is_live) {
            fillArea(table, .{ .x = area.x + 1, .y = row_y, .w = area.w - 2, .h = row_h }, theme.well);
        }

        var label_buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "Branch {d} (p:{d} fork:{d})", .{ it.id, it.parent, it.fork_r }) catch "Branch";
        const text_top = row_y + draw_list.centre(row_h, font.glyph_h);
        drawText(table, area.x + pad, text_top, label, theme.ink, if (it.is_live) theme.well else theme.surface);

        if (it.is_live) {
            drawText(table, area.x + area.w - 50, text_top, "Live", theme.ink, theme.well);
        } else {
            // Switch button
            const sw_btn = Rect{ .x = area.x + area.w - 140, .y = row_y + 2, .w = 50, .h = row_h - 4 };
            fillArea(table, sw_btn, theme.well);
            drawBorder(table, sw_btn, theme.border);
            drawText(table, sw_btn.x + 4, sw_btn.y + 1, "Switch", theme.ink, theme.well);

            if (confirming_id) |cid| {
                if (cid == it.id) {
                    const c_btn = Rect{ .x = area.x + area.w - 85, .y = row_y + 2, .w = 55, .h = row_h - 4 };
                    fillArea(table, c_btn, theme.well);
                    drawBorder(table, c_btn, theme.border);
                    drawText(table, c_btn.x + 2, c_btn.y + 1, "Confirm", theme.ink, theme.well);

                    const x_btn = Rect{ .x = area.x + area.w - 25, .y = row_y + 2, .w = 20, .h = row_h - 4 };
                    fillArea(table, x_btn, theme.well);
                    drawBorder(table, x_btn, theme.border);
                    drawText(table, x_btn.x + 6, x_btn.y + 1, "X", theme.ink, theme.well);
                }
            } else {
                const del_btn = Rect{ .x = area.x + area.w - 45, .y = row_y + 2, .w = 40, .h = row_h - 4 };
                fillArea(table, del_btn, theme.well);
                drawBorder(table, del_btn, theme.border);
                drawText(table, del_btn.x + 6, del_btn.y + 1, "Del", theme.ink, theme.well);
            }
        }
        row_y += row_h;
    }
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
