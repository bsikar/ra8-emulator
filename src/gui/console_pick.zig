//! The console pane's channel pick (RA8EMU-206): a strip of one tab per SCI
//! channel across the top of the pane, the log under it. Clicking a tab
//! shows that channel's log. The shown tab is lit, and a channel that has
//! printed anything is labelled brighter than one that is still empty, so
//! a demo talking on a channel other than the console is easy to find.
const std = @import("std");
const draw_list = @import("draw_list.zig");
const font = @import("font.zig");
const console_log = @import("console_log.zig");
const console_pane = @import("console_pane.zig");

const Color = draw_list.Color;
const Rect = draw_list.Rect;

pub const lit = Color.rgb(0x3B, 0x42, 0x52);
/// Characters the widest label takes: "SCI10".
pub const label_len: usize = 5;
/// One tab: the widest label with the pane's pad either side.
pub const tab_w: i32 = @as(i32, @intCast(font.textWidth(label_len))) + 2 * console_pane.pad;
/// The strip: one text row with the pane's pad above and below.
pub const strip_h: i32 = @as(i32, @intCast(font.cell_h)) + 2 * console_pane.pad;

/// The tab strip across the top of `area`; empty when `area` is shorter.
pub fn strip(area: Rect) Rect {
    if (area.h < strip_h) return .{ .x = area.x, .y = area.y, .w = area.w, .h = 0 };
    return .{ .x = area.x, .y = area.y, .w = area.w, .h = strip_h };
}

/// What is left of `area` under the strip, for the log.
pub fn below(area: Rect) Rect {
    const top = strip(area).h;
    return .{ .x = area.x, .y = area.y + top, .w = area.w, .h = area.h - top };
}

/// The tab of `count` that (`x`, `y`) falls on, if any.
pub fn tabAt(area: Rect, count: usize, x: i32, y: i32) ?usize {
    const row = strip(area);
    if (!row.contains(x, y)) return null;
    const index: usize = @intCast(@divTrunc(x - row.x, tab_w));
    return if (index < count) index else null;
}

pub fn draw(list: *draw_list.DrawList, area: Rect, logs: []const console_log.Log, shown: usize) !void {
    const row = strip(area);
    if (row.h == 0) return;
    try list.fill(row, console_pane.panel);
    try list.pushClip(row);
    defer list.popClip();
    for (logs, 0..) |*log, index| {
        const x = row.x + @as(i32, @intCast(index)) * tab_w;
        const tab = Rect{ .x = x, .y = row.y, .w = tab_w, .h = row.h };
        if (index == shown) try list.fill(tab, lit);
        var buffer: [label_len + 4]u8 = undefined;
        const label = std.fmt.bufPrint(&buffer, "SCI{d}", .{index}) catch continue;
        const busy = log.lines().len > 0 or log.partial().len > 0 or log.dropped > 0;
        try font.draw(list, x + console_pane.pad, row.y + console_pane.pad, label, if (busy) console_pane.ink else console_pane.muted);
    }
}
