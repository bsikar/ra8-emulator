//! Covers src/chip/core/cpu/text/barrier.zig against its parity digest.
const parity = @import("parity.zig");

/// Every hw2 from 0x8F00 to 0x8FFF: DSB, DMB and ISB with each option,
/// plus the neighbouring rows the group leaves unclaimed.
const hw2 = blk: {
    var out: [256]u16 = undefined;
    for (&out, 0..) |*h, i| h.* = 0x8F00 | @as(u16, i);
    break :blk out;
};

test "barrier matches its parity digest for every option" {
    try parity.expectWideGroupMatches("barrier", 0xFFFF, 0xF3BF, &hw2);
}
