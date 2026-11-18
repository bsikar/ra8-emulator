//! Covers `src/chip/periph/fpb.zig`: configurable `num_code` comparator counts,
//! `FP_CTRL` encoding, and instruction address matching.
const ra8 = @import("ra8");
const std = @import("std");

const fpb = ra8.chip.periph.fpb;

test "FP_CTRL encodes configurable NUM_CODE across low and high fields" {
    var four: fpb.Fpb = .{ .num_code = 4 };
    try std.testing.expectEqual(@as(?u32, 0x1000_0040), four.read(fpb.offsets.ctrl));
    try std.testing.expect(four.write(fpb.offsets.comp0 + 3 * 4, 0x0800_0100 | fpb.comp_enable));
    try std.testing.expect(!four.write(fpb.offsets.comp0 + 4 * 4, 0x0800_0200 | fpb.comp_enable));
    try std.testing.expectEqual(@as(?u32, null), four.read(fpb.offsets.comp0 + 4 * 4));

    _ = four.write(fpb.offsets.ctrl, fpb.ctrl_bits.key | fpb.ctrl_bits.enable);
    try std.testing.expectEqual(@as(?usize, 3), four.matches(0x0800_0101));

    var twelve: fpb.Fpb = .{ .num_code = 12 };
    // 12 = 0b01_100: high=1 at [14:12], low=4 at [6:4].
    try std.testing.expectEqual(@as(?u32, 0x1000_1040), twelve.read(fpb.offsets.ctrl));
    try std.testing.expect(twelve.write(fpb.offsets.comp0 + 11 * 4, 0x0200_0400 | fpb.comp_enable));
    _ = twelve.write(fpb.offsets.ctrl, fpb.ctrl_bits.key | fpb.ctrl_bits.enable);
    try std.testing.expectEqual(@as(?usize, 11), twelve.matches(0x0200_0400));

    var absent: fpb.Fpb = .{ .num_code = 0 };
    try std.testing.expectEqual(@as(?u32, fpb.ctrl_bits.rev_v2), absent.read(fpb.offsets.ctrl));
    _ = absent.write(fpb.offsets.ctrl, fpb.ctrl_bits.key | fpb.ctrl_bits.enable);
    try std.testing.expect(!absent.enabled);
}
