//! The shell frame (RA8EMU-764): the docked window chrome drawn from the
//! pane layout (RA8EMU-754). Each leaf gets a title bar naming its pane and
//! the core it is bound to, the splitters show as gutters, and the time bar
//! (RA8EMU-807) and the status strip (RA8EMU-759) run along the bottom, the
//! strip ending in the theme picker (RA8EMU-1165) when the shell has one, and
//! the menu strip (RA8EMU-968) runs across the top, drawn last so an open
//! drop-down covers the panes. What
//! goes inside a leaf comes from a painter, so the window loop fills it and a
//! test can leave it bare.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const pane_layout = @import("../pane_layout.zig");
const status_strip = @import("../status_strip.zig");
const time_bar = @import("../time_bar.zig");
const theme_picker = @import("../theme_picker.zig");
const menu_bar = @import("../../menu_bar.zig");
const widget_paint = @import("ra8_render").widget_paint;
const widget = @import("ra8_widget");
const colors = @import("../colors.zig");
const Theme = colors.Theme;

const Color = draw_list.Color;
const geom = @import("../../geom.zig");
pub const Rect = geom.Rect;
const Pane = pane_layout.Pane;
const Layout = pane_layout.Layout;
const Solved = pane_layout.Solved;

pub const pad: i32 = 4;
pub const title_h: i32 = @as(i32, @intCast(font.cell_h)) + 4;

/// The tab row a deck's child shows instead of a plain title (RA8EMU-958).
pub const Tabs = struct { panes: []const pane_layout.Pane, active: u8 };

/// The `which`th tab cell of a row drawn over `title`, left to right; a
/// cell names its pane and takes its own page. Null when the row has no
/// such cell or it does not fit in the strip.
pub fn tabAt(title: draw_list.Rect, panes: []const pane_layout.Pane, which: usize) ?draw_list.Rect {
    var x = title.x + pad;
    for (panes, 0..) |pane, at| {
        const w: i32 = 2 * pad + @as(i32, @intCast(font.textWidth(kindName(pane.kind).len)));
        if (at == which) {
            if (x + w > title.x + title.w) return null;
            return .{ .x = x, .y = title.y, .w = w, .h = title.h };
        }
        x += w;
    }
    return null;
}

/// Fills one leaf's body. The frame has already cleared it and clipped to it.
pub const Painter = struct {
    context: *anyopaque,
    /// `table` is the shared Paint table over the desktop framebuffer
    /// (RA8EMU-1157); `list` stays until every pane draws through the table.
    paint: *const fn (context: *anyopaque, list: *draw_list.DrawList, table: *const widget.types.Paint, theme: *const Theme, pane: Pane, body: Rect) anyerror!void,
};

/// Everything one frame of the shell shows.
pub const Shell = struct {
    layout: *const Layout,
    solved: *const Solved,
    /// The status strip's view, from src/interfaces/gui/status/capture.zig.
    strip: status_strip.Strip,
    /// The time bar's view, from src/interfaces/gui/shell/time.zig; a bare frame draws it
    /// with nothing lit.
    bar: time_bar.View = .{},
    /// The theme picker at the strip's right end (RA8EMU-1165), from
    /// src/interfaces/gui/shell/theme.zig; a bare frame has none.
    themes: ?theme_picker.View = null,
    /// The menu strip's view (RA8EMU-968): which drop-down is out and what
    /// the enabled rules read; a bare frame has a closed bar.
    menu: menu_bar.Menu = .{},
    width: i32,
    height: i32,
    painter: ?Painter = null,
};

pub fn kindName(kind: pane_layout.Kind) []const u8 {
    return switch (kind) {
        .empty => "Empty",
        .board => "Board",
        .console => "Console",
        .camera => "Camera",
        .devices => "Devices",
        .registers => "Registers",
        .memory => "Memory",
        .disasm => "Disassembly",
        .stack => "Call stack",
        .timeline => "Timeline",
        .source => "Source",
        .locals => "Locals",
        .map => "Memory Map",
    };
}

pub fn coreName(core: pane_layout.Core) []const u8 {
    return switch (core) {
        .cpu0 => "CPU0",
        .cpu1 => "CPU1",
    };
}

/// The panes' share of the window: everything under the menu strip and
/// above the time bar and the status strip.
pub fn panesArea(width: i32, height: i32) Rect {
    return .{ .x = 0, .y = menu_bar.height, .w = width, .h = @max(0, height - menu_bar.height - status_strip.height - time_bar.height) };
}

/// The time bar's row, on top of the status strip.
pub fn barArea(width: i32, height: i32) Rect {
    return .{ .x = 0, .y = height - status_strip.height - time_bar.height, .w = width, .h = time_bar.height };
}

pub fn titleOf(area: draw_list.Rect) draw_list.Rect {
    return .{ .x = area.x, .y = area.y, .w = area.w, .h = @min(title_h, area.h) };
}

pub fn bodyOf(area: draw_list.Rect) draw_list.Rect {
    const top = @min(title_h, area.h);
    return .{ .x = area.x, .y = area.y + top, .w = area.w, .h = area.h - top };
}

/// The status strip's row, under a time bar drawn in `bar`.
pub fn stripUnder(bar: Rect) Rect {
    return .{ .x = bar.x, .y = bar.y + bar.h, .w = bar.w, .h = status_strip.height };
}

/// Lays the panes out for a window of `width` by `height` pixels.
/// The solved layout's rect in the gui geometry (RA8EMU-1157 temporary:
/// the layout still solves in the draw list's rect).
pub fn toGeom(r: draw_list.Rect) Rect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

/// The gui geometry in the draw list's own type (RA8EMU-1157 temporary:
/// leaves and chrome that still paint through the list).
pub fn toList(r: Rect) draw_list.Rect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

pub fn solve(layout: *const Layout, allocator: std.mem.Allocator, width: i32, height: i32) !Solved {
    return layout.solve(allocator, toList(panesArea(width, height)));
}

pub fn draw(list: *draw_list.DrawList, theme: *const Theme, shell: Shell) !void {
    var target = widget_paint.Target{ .list = list };
    const paint = target.paint();
    for (shell.solved.gutters.items) |found| fillArea(&paint, toGeom(found.area), word(theme.gutter));
    var deck_buf: [pane_layout.max_deck]pane_layout.Pane = undefined;
    for (shell.solved.panes.items) |placed| {
        const pane = shell.layout.pane(placed.index) orelse continue;
        var tabs: ?Tabs = null;
        if (shell.layout.deckParent(placed.index)) |parent| {
            if (shell.layout.deckAt(parent)) |deck| {
                for (0..deck.count) |at| {
                    deck_buf[at] = shell.layout.pane(deck.children[at]) orelse .{ .kind = .empty, .core = .cpu0 };
                }
                tabs = .{ .panes = deck_buf[0..deck.count], .active = deck.active };
            }
        }
        try drawLeaf(list, &paint, theme, pane, toGeom(placed.area), shell.painter, tabs);
    }
    time_bar.draw(&paint, theme, toList(barArea(shell.width, shell.height)), shell.bar);
    const strip = status_strip.area(shell.width, shell.height);
    if (shell.themes) |picker| {
        status_strip.draw(&paint, theme, theme_picker.rest(strip), &shell.strip);
        theme_picker.draw(&paint, theme, strip, picker);
    } else status_strip.draw(&paint, theme, strip, &shell.strip);
    // The bar draws last, so an open drop-down covers the panes.
    menu_bar.draw(&paint, theme, shell.menu, shell.width);
}

fn drawLeaf(list: *draw_list.DrawList, table: *const widget.types.Paint, theme: *const Theme, pane: Pane, area: Rect, painter: ?Painter, tabs: ?Tabs) !void {
    if (geom.empty(area)) return;
    try list.pushClip(toList(area));
    defer list.popClip();
    fillArea(table, area, word(theme.background));
    const title = toGeom(titleOf(toList(area)));
    fillArea(table, title, word(theme.face));
    fillArea(table, .{ .x = title.x, .y = title.y + title.h - 1, .w = title.w, .h = 1 }, word(theme.border));
    const top = title.y + draw_list.centre(title.h, font.glyph_h);
    if (tabs) |row| {
        for (row.panes, 0..) |tab, at| {
            const cell = toGeom(tabAt(toList(title), row.panes, at) orelse continue);
            const lit = at == row.active;
            if (lit) fillArea(table, cell, word(theme.background));
            const label = kindName(tab.kind);
            const mid = cell.x + draw_list.centre(cell.w, @intCast(font.textWidth(label.len)));
            drawText(table, mid, top, label, word(if (lit) theme.ink else theme.muted), word(if (lit) theme.background else theme.face));
        }
    } else {
        const core = coreName(pane.core);
        const core_w: i32 = @intCast(font.textWidth(core.len));
        const room = title.w - 2 * pad;
        if (room > 0) drawText(table, title.x + pad, top, font.fit(kindName(pane.kind), @intCast(room)), word(theme.ink), word(theme.face));
        const name_w: i32 = @intCast(font.textWidth(kindName(pane.kind).len));
        if (room >= name_w + pad + core_w) drawText(table, title.x + title.w - pad - core_w, top, core, word(theme.muted), word(theme.face));
    }
    if (painter) |p| {
        const body = toGeom(bodyOf(toList(area)));
        if (!geom.empty(body)) {
            try list.pushClip(toList(body));
            defer list.popClip();
            try p.paint(p.context, list, table, theme, pane, body);
        }
    }
    drawBorder(table, area, theme.border);
}

fn drawBorder(table: *const widget.types.Paint, area: Rect, color: Color) void {
    if (area.w <= 0 or area.h <= 0) return;
    fillArea(table, .{ .x = area.x, .y = area.y, .w = area.w, .h = 1 }, word(color));
    fillArea(table, .{ .x = area.x, .y = area.y + area.h - 1, .w = area.w, .h = 1 }, word(color));
    fillArea(table, .{ .x = area.x, .y = area.y, .w = 1, .h = area.h }, word(color));
    fillArea(table, .{ .x = area.x + area.w - 1, .y = area.y, .w = 1, .h = area.h }, word(color));
}

/// `area` filled with `color` through the shared Paint table (RA8EMU-1157).
fn fillArea(table: *const widget.types.Paint, area: Rect, color: u32) void {
    table.fill_rect.?(table.user, area.x, area.y, area.w, area.h, color);
}

/// One line of title text as the firmware's label widget (RA8EMU-1157), the
/// pane pattern: pad 0, left-aligned, rect = the text's own cell.
fn drawText(table: *const widget.types.Paint, x: i32, y: i32, text: []const u8, fg: u32, bg: u32) void {
    var buffer: [64]u8 = undefined;
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

/// `color` as the widget's 0x00RRGGBB colour word.
fn word(color: Color) u32 {
    return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
}
