//! Covers src/gui/board_snapshot.zig: a publish copies the panel and LEDs
//! so later board changes don't reach the UI's view, a resized panel gets
//! its own pixels, the size of each handoff is reported, and nothing
//! leaks across slots.
const std = @import("std");
const ra8 = @import("ra8");
const snapshot = ra8.gui.board_snapshot;
const Led = snapshot.Led;

test "nothing until a publish, then a copy the board can't change" {
    var handoff = snapshot.Handoff.init(std.testing.allocator);
    defer handoff.deinit();
    try std.testing.expect(handoff.latest() == null);
    var panel = [_]u32{ 1, 2, 3, 4 };
    const leds = [_]Led{ .{ .rgb565 = 0xF800, .on = true }, .{ .rgb565 = 0x07E0, .on = false } };
    const sent = try handoff.publish(.{ .panel = &panel, .width = 2, .height = 2, .leds = &leds });
    try std.testing.expectEqual(@as(usize, 4 * 4 + 2 * @sizeOf(Led)), sent);
    panel[0] = 99;
    const seen = handoff.latest().?;
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, seen.panel);
    try std.testing.expectEqual(@as(u32, 2), seen.width);
    try std.testing.expect(seen.leds[0].on and !seen.leds[1].on);
    try std.testing.expect(handoff.latest() == null);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, handoff.current().panel);
}

test "a resized panel arrives whole and the newest publish wins" {
    var handoff = snapshot.Handoff.init(std.testing.allocator);
    defer handoff.deinit();
    const small = [_]u32{7} ** 4;
    const big = [_]u32{9} ** 12;
    _ = try handoff.publish(.{ .panel = &small, .width = 2, .height = 2, .leds = &.{} });
    _ = try handoff.publish(.{ .panel = &big, .width = 4, .height = 3, .leds = &.{} });
    const seen = handoff.latest().?;
    try std.testing.expectEqual(@as(usize, 12), seen.panel.len);
    try std.testing.expectEqual(@as(u32, 9), seen.panel[11]);
    for (0..6) |i| _ = try handoff.publish(.{ .panel = if (i % 2 == 0) &small else &big, .width = 1, .height = 1, .leds = &.{} });
    try std.testing.expectEqual(@as(usize, 12), handoff.latest().?.panel.len);
    try std.testing.expectEqual(@as(usize, 12 * 4), handoff.max_bytes.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 12 * 4), handoff.last_bytes);
}

test "more LEDs than a slot holds are refused" {
    var handoff = snapshot.Handoff.init(std.testing.allocator);
    defer handoff.deinit();
    const leds = [_]Led{.{ .rgb565 = 0, .on = false }} ** (snapshot.max_leds + 1);
    try std.testing.expectError(error.TooManyLeds, handoff.publish(.{ .panel = &.{}, .width = 0, .height = 0, .leds = &leds }));
    try std.testing.expect(handoff.latest() == null);
}
