//! WDT0's count rate: the bench reading and the six legal dividers.
const std = @import("std");
const ra8 = @import("ra8");

const clock = ra8.periph.wdt.clock;

test "CKS /4 counts at the bench's 40 Hz: 500 ticks of 50000 instructions" {
    try std.testing.expectEqual(@as(u32, 500), clock.ticksPerCount(0x1));
}

test "the six legal encodings decode to the dividers ra8_wdt.h names" {
    const pairs = [_][2]u32{ .{ 0x1, 4 }, .{ 0x4, 64 }, .{ 0xF, 128 }, .{ 0x6, 512 }, .{ 0x7, 2048 }, .{ 0x8, 8192 } };
    for (pairs) |pair| try std.testing.expectEqual(pair[1], clock.divider(@intCast(pair[0])));
}

test "a larger divider counts proportionally slower" {
    try std.testing.expectEqual(clock.ticksPerCount(0x1) * 2048, clock.ticksPerCount(0x8));
}

test "a prohibited encoding counts at the bench rate" {
    try std.testing.expectEqual(clock.ticksPerCount(0x1), clock.ticksPerCount(0x0));
    try std.testing.expectEqual(clock.ticksPerCount(0x1), clock.ticksPerCount(0x2));
}
