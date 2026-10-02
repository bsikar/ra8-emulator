//! Covers src/core/cpu/exception/exc_return.zig.
const std = @import("std");
const exc_return = @import("ra8").core.cpu.exception.exc_return;

test "entry makes the Secure basic-frame values for each mode and stack" {
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF9), exc_return.forEntry(.{ .thread = true, .psp = false }));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFD), exc_return.forEntry(.{ .thread = true, .psp = true }));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF1), exc_return.forEntry(.{ .thread = false, .psp = false }));
}

test "decode gives back what entry encoded" {
    for ([_]exc_return.Target{
        .{ .thread = true, .psp = false },
        .{ .thread = true, .psp = true },
        .{ .thread = false, .psp = false },
    }) |target| {
        try std.testing.expectEqual(target, exc_return.decode(exc_return.forEntry(target)).?);
    }
}

test "decode turns away the forms the core does not make" {
    try std.testing.expectEqual(@as(?exc_return.Target, null), exc_return.decode(0xFFFF_FFFF)); // reserved bit 1: LR at reset
    try std.testing.expectEqual(@as(?exc_return.Target, null), exc_return.decode(0xFFFF_FFF5)); // Handler on the PSP
    try std.testing.expectEqual(@as(?exc_return.Target, null), exc_return.decode(0xFFFF_FFE9)); // FP frame
    try std.testing.expectEqual(@as(?exc_return.Target, null), exc_return.decode(0xFFFF_FFB9)); // Non-secure stack
    try std.testing.expectEqual(@as(?exc_return.Target, null), exc_return.decode(0xFFFF_FFF8)); // Non-secure exception
    try std.testing.expectEqual(@as(?exc_return.Target, null), exc_return.decode(0xFFFF_FF79)); // bit 7 clear
}

test "only bits 31:24 all set mark an exception return" {
    try std.testing.expect(exc_return.marks(0xFFFF_FFF9));
    try std.testing.expect(exc_return.marks(0xFF00_0000));
    try std.testing.expect(!exc_return.marks(0xFEFF_FFFF));
    try std.testing.expect(!exc_return.marks(0x2000_0101));
}
