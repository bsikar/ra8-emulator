const std = @import("std");
const ra8 = @import("ra8");
const to_int = ra8.core.fpu.to_int;

test "saturation picks the nearest end of each range" {
    try std.testing.expectEqual(@as(u32, 0x7FFF_FFFF), to_int.saturate(0, false));
    try std.testing.expectEqual(@as(u32, 0x8000_0000), to_int.saturate(1, false));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), to_int.saturate(0, true));
    try std.testing.expectEqual(@as(u32, 0), to_int.saturate(1, true));
}

test "an exact cut never rounds up" {
    try std.testing.expect(!to_int.roundsUp(.{ .int = 3, .err = .none }, 0, .plus_inf));
}

test "a tie rounds up only from an odd magnitude" {
    try std.testing.expect(to_int.roundsUp(.{ .int = 3, .err = .half }, 0, .nearest));
    try std.testing.expect(!to_int.roundsUp(.{ .int = 2, .err = .half }, 1, .nearest));
}

test "the directed modes move the magnitude only toward their infinity" {
    try std.testing.expect(to_int.roundsUp(.{ .int = 2, .err = .below_half }, 1, .minus_inf));
    try std.testing.expect(!to_int.roundsUp(.{ .int = 2, .err = .above_half }, 1, .plus_inf));
}
