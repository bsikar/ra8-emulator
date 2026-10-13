//! The in-window menu bar (RA8EMU-968, RA8EMU-957): the Linux strip drawn by
//! our own immediate-mode widgets from the RA8EMU-967 model (no GTK). A press
//! on a title opens its drop-down, a press on an item fires its action, and
//! Escape or a click outside closes it; disabled items draw muted and never
//! fire. The shell lays its panes out below the strip and draws the bar last,
//! so an open drop-down covers the panes. This file lays out, paints and
//! hit-tests, and it returns the fired Action instead of calling the shell,
//! the same as the time bar's controls, so it tests headless with no session.
//! Windows and macOS skip the strip once their native slices land.
const std = @import("std");
const builtin = @import("builtin");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const widget = @import("ra8_widget");
const colors = @import("ui/colors.zig");
const menu = @import("menu.zig");

const Color = draw_list.Color;
const Rect = draw_list.Rect;
const Theme = colors.Theme;

/// The strip's height: a title's text with air above and below.
pub const height: i32 = @as(i32, @intCast(font.cell_h)) + 6;
/// A drop-down row: the item's text with air above and below.
pub const row_h: i32 = @as(i32, @intCast(font.glyph_h)) + 4;
/// Air left and right of a title and of an item's text.
pub const pad: i32 = 4;
/// The air above a divided row, holding its divider line.
pub const divide: i32 = 2;

/// The bar's state: which drop-down, if any, is out.
pub const Bar = struct {
    open: ?usize = null,
};

/// The shell's menu model: the bar's state, what the enabled rules read,
/// and the OS the shortcuts print for.
pub const Menu = struct {
    bar: Bar = .{},
    state: menu.State = .{},
    os: std.Target.Os.Tag = builtin.os.tag,
    /// The menus to render (RA8EMU-1153): the model's own, or a shell's
    /// laid-in ones.
    menus: []const menu.Menu = &menu.bar,
};

/// Title `index` of the bar, laid left to right from the window's edge.
pub fn title(menus: []const menu.Menu, width: i32, index: usize) Rect {
    var x: i32 = 0;
    for (menus, 0..) |m, at| {
        const w = 2 * pad + @as(i32, @intCast(font.textWidth(m.title.len)));
        if (at == index) return .{ .x = x, .y = 0, .w = w, .h = height };
        x += w;
    }
    _ = width;
    return .{ .x = x, .y = 0, .w = 0, .h = height };
}

/// The drop-down's width: the widest shown item's label and shortcut with
/// air around each, over a floor of four pads.
pub fn dropWidth(menus: []const menu.Menu, index: usize, os: std.Target.Os.Tag) i32 {
    var w: i32 = 4 * pad;
    var buf: [16]u8 = undefined;
    for (menus[index].items) |item| {
        if (!menu.shows(item, os)) continue;
        const air: i32 = if (item.shortcut == null) 3 * pad else 2 * pad;
        var item_w = air + @as(i32, @intCast(font.textWidth(item.label.len)));
        if (item.shortcut) |s| {
            const text = menu.text(s, os, &buf) catch unreachable;
            item_w += pad + @as(i32, @intCast(font.textWidth(text.len)));
        }
        w = @max(w, item_w);
    }
    return w;
}

/// The drop-down under title `index`: one outline row, each shown item's row,
/// and the air above each divided row.
pub fn drop(menus: []const menu.Menu, width: i32, index: usize, os: std.Target.Os.Tag) Rect {
    const at = title(menus, width, index);
    var h: i32 = 1;
    for (menus[index].items) |item| {
        if (!menu.shows(item, os)) continue;
        h += row_h + (if (item.divided) divide else 0);
    }
    return .{ .x = at.x, .y = height, .w = dropWidth(menus, index, os), .h = h };
}

/// Row `at` of the drop-down, over the menu's shown items.
pub fn row(menus: []const menu.Menu, width: i32, index: usize, at: usize, os: std.Target.Os.Tag) Rect {
    const box = drop(menus, width, index, os);
    var y: i32 = box.y + 1;
    var seen: usize = 0;
    for (menus[index].items) |item| {
        if (!menu.shows(item, os)) continue;
        if (item.divided) y += divide;
        if (seen == at) return .{ .x = box.x, .y = y, .w = box.w, .h = row_h };
        y += row_h;
        seen += 1;
    }
    return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
}

/// The shown item the drop-down numbers `at`, or null past the end.
fn shownAt(m: menu.Menu, at: usize, os: std.Target.Os.Tag) ?menu.Item {
    var seen: usize = 0;
    for (m.items) |item| {
        if (!menu.shows(item, os)) continue;
        if (seen == at) return item;
        seen += 1;
    }
    return null;
}

pub const Hit = union(enum) { title: usize, item: usize };

/// What (`x`, `y`) lands on: a title, or an item of the open drop-down.
pub fn hit(bar: Bar, menus: []const menu.Menu, width: i32, os: std.Target.Os.Tag, x: i32, y: i32) ?Hit {
    for (0..menus.len) |index| {
        if (title(menus, width, index).contains(x, y)) return .{ .title = index };
    }
    const open = bar.open orelse return null;
    if (!drop(menus, width, open, os).contains(x, y)) return null;
    for (0..menus[open].items.len) |at| {
        if (row(menus, width, open, at, os).contains(x, y)) return .{ .item = at };
    }
    return null;
}

/// What a press on the bar did.
pub const Press = union(enum) {
    /// Nothing of the bar's was pressed; the panes get the event.
    missed,
    /// The bar took the press without firing: open, close, switch, or an
    /// item that is disabled.
    taken,
    fire: menu.Action,
};

/// Applies a press at (`x`, `y`) and reports what it did. A press outside
/// the bar and an open drop-down closes the drop-down and is the shell's to
/// route; with nothing open it falls through to the panes.
pub fn press(bar: *Bar, view: Menu, width: i32, x: i32, y: i32) Press {
    const found = hit(bar.*, view.menus, width, view.os, x, y) orelse {
        const had = bar.open != null;
        bar.open = null;
        return if (had) .taken else .missed;
    };
    switch (found) {
        .title => |index| {
            bar.open = if (bar.open == index) null else index;
            return .taken;
        },
        .item => |at| {
            const open = bar.open.?;
            const item = shownAt(view.menus[open], at, view.os) orelse return .taken;
            if (!menu.enabled(item.action, view.state)) return .taken;
            bar.open = null;
            return .{ .fire = item.action };
        },
    }
}

/// Closes the open drop-down, reporting whether one was out.
pub fn escape(bar: *Bar) bool {
    const had = bar.open != null;
    bar.open = null;
    return had;
}

/// Dragging across the titles moves the open drop-down, the way a menu bar
/// does while the button is down.
pub fn hover(bar: *Bar, menus: []const menu.Menu, width: i32, x: i32) void {
    const open = bar.open orelse return;
    for (0..menus.len) |index| {
        if (index != open and title(menus, width, index).contains(x, 0)) {
            bar.open = index;
            return;
        }
    }
}

/// Draws the strip across the top of a window `width` wide. Draw it after
/// the panes and the bottom chrome, so an open drop-down covers them.
pub fn draw(table: *const widget.types.Paint, theme: *const Theme, view: Menu, width: i32) void {
    fillArea(table, .{ .x = 0, .y = 0, .w = width, .h = height }, theme.face);
    fillArea(table, .{ .x = 0, .y = height - 1, .w = width, .h = 1 }, theme.border);
    const top = @divFloor(height - @as(i32, font.glyph_h), 2);
    for (view.menus, 0..) |m, index| {
        const at = title(view.menus, width, index);
        const hot = view.bar.open == index;
        if (hot) fillArea(table, at, theme.band);
        drawText(table, at.x + pad, top, m.title, if (hot) theme.highlight else theme.ink, theme.face);
    }
    const open = view.bar.open orelse return;
    const box = drop(view.menus, width, open, view.os);
    fillArea(table, box, theme.face);
    outline(table, theme.control_border, box);
    for (0..view.menus[open].items.len) |at| drawItem(table, theme, view, width, open, at);
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

fn drawItem(table: *const widget.types.Paint, theme: *const Theme, view: Menu, width: i32, open: usize, at: usize) void {
    const item = shownAt(view.menus[open], at, view.os) orelse return;
    const area = row(view.menus, width, open, at, view.os);
    if (item.divided) {
        const line = area.y - divide;
        fillArea(table, .{ .x = area.x, .y = line, .w = area.w, .h = 1 }, theme.border);
    }
    const ok = menu.enabled(item.action, view.state);
    const top = area.y + @divFloor(area.h - @as(i32, font.glyph_h), 2);
    drawText(table, area.x + pad, top, menu.label(item, view.state), if (ok) theme.ink else theme.muted, theme.face);
    const bound = item.shortcut orelse return;
    var buf: [16]u8 = undefined;
    const text = menu.text(bound, view.os, &buf) catch return;
    const w: i32 = @intCast(font.textWidth(text.len));
    drawText(table, area.x + area.w - pad - w, top, text, theme.muted, theme.face);
}

/// One pixel of `color` round the inside of `area`.
/// One pixel of `color` round the inside of `area`.
fn outline(table: *const widget.types.Paint, color: Color, area: Rect) void {
    fillArea(table, .{ .x = area.x, .y = area.y, .w = area.w, .h = 1 }, color);
    fillArea(table, .{ .x = area.x, .y = area.y + area.h - 1, .w = area.w, .h = 1 }, color);
    fillArea(table, .{ .x = area.x, .y = area.y, .w = 1, .h = area.h }, color);
    fillArea(table, .{ .x = area.x + area.w - 1, .y = area.y, .w = 1, .h = area.h }, color);
}
