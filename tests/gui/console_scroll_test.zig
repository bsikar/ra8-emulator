//! Covers src/gui/console_scroll.zig: a wheel notch moves three lines, the
//! offset stops at the oldest line and at the bottom, a fine wheel adds up
//! to whole lines, and new output leaves a scrolled-back view where it was.
const std = @import("std");
const ra8 = @import("ra8");
const console_log = ra8.gui.console_log;
const Scroll = ra8.gui.console_scroll.Scroll;

fn logOf(lines: usize) !console_log.Log {
    var log = console_log.Log.init(std.testing.allocator, 4);
    errdefer log.deinit();
    for (0..lines) |_| try log.feedAll("x\n", 0);
    return log;
}

test "a notch up goes back three lines and a notch down comes forward" {
    var log = try logOf(4);
    defer log.deinit();
    var scroll = Scroll{};
    scroll.wheel(1, &log);
    try std.testing.expectEqual(@as(usize, 3), scroll.back);
    scroll.wheel(-1, &log);
    try std.testing.expectEqual(@as(usize, 0), scroll.back);
}

test "the offset stops at the oldest line and at the bottom" {
    var log = try logOf(4);
    defer log.deinit();
    var scroll = Scroll{};
    scroll.wheel(5, &log);
    try std.testing.expectEqual(@as(usize, 4), scroll.back);
    scroll.wheel(-9, &log);
    try std.testing.expectEqual(@as(usize, 0), scroll.back);
    scroll.wheel(0.5, &log);
    try std.testing.expectEqual(@as(usize, 1), scroll.back);
}

test "fine wheel turns add up to whole lines" {
    var log = try logOf(4);
    defer log.deinit();
    var scroll = Scroll{};
    scroll.wheel(0.2, &log);
    try std.testing.expectEqual(@as(usize, 0), scroll.back);
    scroll.wheel(0.2, &log);
    try std.testing.expectEqual(@as(usize, 1), scroll.back);
}

test "new lines leave a scrolled-back view where it was and the bottom follows" {
    var log = try logOf(3);
    defer log.deinit();
    var scroll = Scroll{};
    scroll.follow(&log);
    try log.feedAll("y\n", 0);
    scroll.follow(&log);
    try std.testing.expectEqual(@as(usize, 0), scroll.back);
    scroll.wheel(0.5, &log);
    try std.testing.expectEqual(@as(usize, 1), scroll.back);
    // A fifth line drops the oldest; the view moves back one to hold still.
    try log.feedAll("z\n", 0);
    scroll.follow(&log);
    try std.testing.expectEqual(@as(usize, 2), scroll.back);
}
