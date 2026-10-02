//! Covers src/core/cpu/lockstep/tap_hook.zig.
const std = @import("std");
const ra8 = @import("ra8");
const tap_hook = ra8.core.cpu.lockstep.tap_hook;

test "mask keeps only the bytes the access carried" {
    try std.testing.expectEqual(@as(u32, 0xEF), tap_hook.mask(0xDEAD_BEEF, 1));
    try std.testing.expectEqual(@as(u32, 0xBEEF), tap_hook.mask(0xDEAD_BEEF, 2));
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), tap_hook.mask(0xDEAD_BEEF, 4));
}
