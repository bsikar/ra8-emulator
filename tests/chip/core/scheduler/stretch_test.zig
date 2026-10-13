//! The frozen width uses board edges, and survives caller boundaries.
const std = @import("std");
const stretch = @import("ra8").chip.core.scheduler.stretch;

test "grid strict Stretch stays frozen and time projection includes uncharged sleep" {
    var saved: stretch.Stretch = .{};
    saved.open(stretch.width(100, &.{ 90, 300, 0 }, false));
    saved.carry = 17;
    saved.open(200);
    try std.testing.expectEqual(@as(u32, 90), saved.full);
    try std.testing.expectEqual(@as(u32, 73), saved.left());
    try std.testing.expectEqual(@as(u64, 1017), saved.nowAfter(1000));
    try std.testing.expectEqual(@as(u32, 300), stretch.width(100, &.{ 0, 300, 900 }, true));
    try std.testing.expectEqual(@as(u32, 100), stretch.width(100, &.{ 300, 900 }, false));
}
