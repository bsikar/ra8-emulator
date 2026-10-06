//! The recv flags the host loops peek with (RA8EMU-726).
const std = @import("std");
const builtin = @import("builtin");
const flags = @import("ra8").interfaces.socket_flags;

test "off Darwin the flags are the std.posix values" {
    if (builtin.os.tag.isDarwin()) return error.SkipZigTest;
    try std.testing.expectEqual(@as(u32, std.posix.MSG.PEEK), flags.peek);
    try std.testing.expectEqual(@as(u32, std.posix.MSG.DONTWAIT), flags.dontwait);
}

test "on Darwin the flags are the sys/socket.h values" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    try std.testing.expectEqual(@as(u32, 0x2), flags.peek);
    try std.testing.expectEqual(@as(u32, 0x80), flags.dontwait);
}

test "peek and dontwait are distinct single bits" {
    try std.testing.expectEqual(@as(u32, 1), @popCount(flags.peek));
    try std.testing.expectEqual(@as(u32, 1), @popCount(flags.dontwait));
    try std.testing.expectEqual(@as(u32, 0), flags.peek & flags.dontwait);
}
