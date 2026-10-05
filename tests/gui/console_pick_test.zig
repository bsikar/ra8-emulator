//! Covers src/gui/console_pick.zig: the strip takes one row off the top of
//! the pane, a click lands on the tab under it and nowhere else, and the
//! strip draws one label per channel with the shown one lit.
const std = @import("std");
const ra8 = @import("ra8");
const console_log = ra8.gui.console_log;
const console_pick = ra8.gui.console_pick;
const draw_list = ra8.gui.draw_list;

const area = draw_list.Rect{ .x = 0, .y = 100, .w = 400, .h = 60 };

test "the strip takes one row off the top and the log gets the rest" {
    const row = console_pick.strip(area);
    const rest = console_pick.below(area);
    try std.testing.expectEqual(console_pick.strip_h, row.h);
    try std.testing.expectEqual(area.y + console_pick.strip_h, rest.y);
    try std.testing.expectEqual(area.h - console_pick.strip_h, rest.h);
    const short = draw_list.Rect{ .x = 0, .y = 0, .w = 400, .h = console_pick.strip_h - 1 };
    try std.testing.expectEqual(@as(i32, 0), console_pick.strip(short).h);
    try std.testing.expectEqual(short.h, console_pick.below(short).h);
}

test "a click lands on the tab under it and nowhere else" {
    const y = area.y + 2;
    try std.testing.expectEqual(@as(?usize, 0), console_pick.tabAt(area, 10, 1, y));
    try std.testing.expectEqual(@as(?usize, 3), console_pick.tabAt(area, 10, 3 * console_pick.tab_w + 1, y));
    try std.testing.expectEqual(@as(?usize, null), console_pick.tabAt(area, 2, 3 * console_pick.tab_w + 1, y));
    try std.testing.expectEqual(@as(?usize, null), console_pick.tabAt(area, 10, 1, area.y + console_pick.strip_h));
    try std.testing.expectEqual(@as(?usize, null), console_pick.tabAt(area, 10, 1, area.y - 1));
}

test "the strip draws one label per channel and lights the shown one" {
    var logs: [3]console_log.Log = undefined;
    for (&logs) |*log| log.* = .init(std.testing.allocator, 4);
    defer for (&logs) |*log| log.deinit();
    try logs[2].feedAll("hi\n", 1);
    var list = draw_list.DrawList.init(std.testing.allocator, 400, 200);
    defer list.deinit();
    try console_pick.draw(&list, area, &logs, 1);
    var glyphs: usize = 0;
    var lit: usize = 0;
    for (list.commands.items) |command| {
        if (command.shape == .glyph) glyphs += 1;
        if (command.shape == .fill and std.meta.eql(command.shape.fill.color, console_pick.lit)) lit += 1;
    }
    try std.testing.expectEqual(@as(usize, 3 * 4), glyphs);
    try std.testing.expectEqual(@as(usize, 1), lit);
}
