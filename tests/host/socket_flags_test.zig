//! The no-SIGPIPE send flag in src/host/socket_flags.zig (RA8EMU-726).
const std = @import("std");
const builtin = @import("builtin");
const flags = @import("ra8").host.socket_flags;

test "off Darwin nosignal is the std.posix value, or 0 without one" {
    if (builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const nosignal: u32 = if (@hasDecl(std.posix.MSG, "NOSIGNAL")) std.posix.MSG.NOSIGNAL else 0;
    try std.testing.expectEqual(nosignal, flags.nosignal);
}

test "on Darwin nosignal is the sys/socket.h value" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    try std.testing.expectEqual(@as(u32, 0x80000), flags.nosignal);
}
