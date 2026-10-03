//! Covers src/core/cpu/text/barrier.zig against Capstone.
const capstone = @import("capstone.zig");

/// Every hw2 from 0x8F00 to 0x8FFF: DSB, DMB and ISB with each option,
/// plus the neighbouring rows the group leaves unclaimed.
const hw2 = blk: {
    var out: [256]u16 = undefined;
    for (&out, 0..) |*h, i| h.* = 0x8F00 | @as(u16, i);
    break :blk out;
};

test "barrier prints the way Capstone does for every option" {
    try capstone.expectWideGroupMatches("barrier", 0xFFFF, 0xF3BF, &hw2);
}
