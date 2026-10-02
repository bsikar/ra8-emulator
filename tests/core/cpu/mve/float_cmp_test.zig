//! Covers src/core/cpu/mve/float_cmp.zig.
const std = @import("std");
const ra8 = @import("ra8");
const float_cmp = ra8.core.mve.float_cmp;

test "a lane runs when its first byte is predicated, then the mask clips its bytes" {
    var fpscr: ra8.core.fpu.fpscr.Fpscr = .{};
    const ones: u128 = 0x3F800000_3F800000_3F800000_3F800000;
    try std.testing.expectEqual(@as(u16, 0x3030), float_cmp.compare(ones, ones, .word, .eq, 0x3C3C, &fpscr));
}

test "a compare raises nothing for an inactive NaN lane" {
    var fpscr: ra8.core.fpu.fpscr.Fpscr = .{};
    const n: u128 = 0x7F800001_00000000_00000000_00000000;
    try std.testing.expectEqual(@as(u16, 0x0FFF), float_cmp.compare(n, 0, .word, .ge, 0x0FFF, &fpscr));
    try std.testing.expectEqual(@as(u1, 0), fpscr.ioc);
}
