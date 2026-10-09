//! Covers src/chip/core/cpu/text/usad8.zig against its parity digest.
const parity = @import("parity.zig");

/// Every Ra (1111 is USAD8, SP unclaimed) with Rd r0 and r12 and Rm r2 and
/// r12, plus SP as Rd and a set hw2[4] (unclaimed).
const hw2 = blk: {
    var out: [16 * 4 + 2]u16 = undefined;
    var i: usize = 0;
    for (0..16) |ra| {
        for ([_]u16{ 0x002, 0xC0C, 0x00C, 0xC02 }) |rd_rm| {
            out[i] = (@as(u16, ra) << 12) | rd_rm;
            i += 1;
        }
    }
    out[i] = 0xFD02;
    out[i + 1] = 0xF012;
    break :blk out;
};

test "USAD8 and USADA8 match their parity digests" {
    try parity.expectWideGroupMatches("usad8", 0xFFF0, 0xFB70, &hw2);
}
