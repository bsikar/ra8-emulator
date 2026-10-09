//! Covers src/chip/core/cpu/text/ldrd_strd.zig against its parity digest.
const parity = @import("parity.zig");

/// Zero, decimal and hex offsets around the ten boundary, the largest
/// offset, SP and PC as Rt or Rt2, Rt equal to Rt2, and Rt or Rt2 equal to
/// a low Rn (the writeback-overlap cases, unclaimed).
const hw2 = [_]u16{
    0x1200, 0x1202, 0x1203, 0x12FF, 0x1201, 0x340A,
    0xD200, 0x1D02, 0xF202, 0x1F02, 0x1102, 0x0102,
    0x1002, 0x2104, 0xC7E0, 0x6540,
};

test "ldrd_strd matches its parity digest for every addressing mode" {
    try parity.expectWideGroupMatches("ldrd_strd", 0xFE40, 0xE840, &hw2);
}
