//! Tests for src/interfaces/gui/display_settings.zig: the time between
//! frames each choice asks for, and the saved text's round trip and
//! tolerance of what it does not know.
const std = @import("std");
const gui_app = @import("gui_app");

const display_settings = gui_app.display_settings;
const Display = display_settings.Display;
const ns_per_s = std.time.ns_per_s;

test "with vsync and no limit a frame lasts one refresh of the display" {
    const display: Display = .{};
    try std.testing.expect(display.vsync);
    try std.testing.expectEqual(display_settings.Limit.none, display.limit);
    try std.testing.expectEqual(ns_per_s / 60, display.interval(60_000));
    try std.testing.expectEqual(ns_per_s / 144, display.interval(144_000));
    // 59.94 Hz, as a display reports it.
    try std.testing.expectEqual(ns_per_s * 1000 / 59_940, display.interval(59_940));
}

test "a display that does not say its refresh is taken for sixty hertz" {
    const display: Display = .{};
    try std.testing.expectEqual(ns_per_s / display_settings.fallback_hz, display.interval(0));
}

test "a limit under the refresh rate wins, and one over it does not" {
    var display: Display = .{ .limit = .fps30 };
    try std.testing.expectEqual(ns_per_s / 30, display.interval(144_000));
    display.limit = .fps240;
    try std.testing.expectEqual(ns_per_s / 144, display.interval(144_000));
}

test "without vsync only the limit paces, and no limit is no wait at all" {
    var display: Display = .{ .vsync = false, .limit = .fps120 };
    try std.testing.expectEqual(ns_per_s / 120, display.interval(60_000));
    display.limit = .none;
    try std.testing.expectEqual(@as(u64, 0), display.interval(60_000));
    try std.testing.expectEqual(@as(u64, 0), display.interval(0));
}

test "every limit names its rate" {
    try std.testing.expectEqual(@as(?u32, 30), display_settings.Limit.fps30.hz());
    try std.testing.expectEqual(@as(?u32, 240), display_settings.Limit.fps240.hz());
    try std.testing.expectEqual(@as(?u32, null), display_settings.Limit.none.hz());
    try std.testing.expectEqualStrings("144", display_settings.Limit.fps144.label());
    try std.testing.expectEqualStrings("None", display_settings.Limit.none.label());
}

test "the saved text round-trips every choice" {
    var buf: [64]u8 = undefined;
    const all = [_]Display{
        .{},
        .{ .vsync = false, .limit = .fps144, .counter = true },
        .{ .vsync = true, .limit = .fps30, .counter = true },
        .{ .vsync = false, .limit = .none, .counter = false },
    };
    for (all) |display| try std.testing.expectEqual(display, Display.parse(display.write(&buf)));
    try std.testing.expectEqualStrings("vsync=off\nlimit=144\ncounter=on\n", all[1].write(&buf));
}

test "a line the build does not know, or a value it does not offer, keeps the default" {
    try std.testing.expectEqual(Display{}, Display.parse(""));
    try std.testing.expectEqual(Display{}, Display.parse("banana\nvsync=maybe\nlimit=75\ncounter\n"));
    const some = Display.parse("scale=2\r\n counter = on \r\nlimit=120\n");
    try std.testing.expectEqual(Display{ .limit = .fps120, .counter = true }, some);
}
