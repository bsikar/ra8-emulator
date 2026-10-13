//! Position ordering and per-core slot mapping.
const std = @import("std");
const Position = @import("ra8").chip.core.scheduler.Position;

test "grid strict Position mapping distinguishes both core phases and atomic board gaps" {
    const base: [2]u64 = .{ 300, 170 };
    const lengths: [2]u32 = .{ 16, 8 };
    const cpu0: Position = .{ .r = 7, .o = 15, .gap = .polled };
    const cpu1: Position = .{ .r = 7, .phase = .cpu1, .o = 3, .gap = .retired };
    const board: Position = .{ .r = 7, .phase = .board, .o = 1 };
    try std.testing.expectEqual(@as(u64, 315), cpu0.slots(0, base, lengths));
    try std.testing.expectEqual(@as(u64, 170), cpu0.slots(1, base, lengths));
    try std.testing.expectEqual(@as(u64, 316), cpu1.slots(0, base, lengths));
    try std.testing.expectEqual(@as(u64, 173), cpu1.slots(1, base, lengths));
    try std.testing.expectEqual(@as(u64, 178), board.slots(1, base, lengths));
    try std.testing.expectEqual(std.math.Order.lt, Position.order(cpu0, cpu1).?);
    try std.testing.expectEqual(std.math.Order.lt, Position.order(cpu1, board).?);
    try std.testing.expectEqual(@as(?std.math.Order, null), Position.order(cpu0, .{ .branch = 1 }));
}
