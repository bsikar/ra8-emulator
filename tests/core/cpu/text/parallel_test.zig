//! Covers src/core/cpu/text/parallel.zig against its parity digest.
const parity = @import("parity.zig");

/// Every U and op2 (op2 11 unclaimed) with Rd/Rm low, high and mixed, plus SP
/// as Rd and a set hw2[7] (both unclaimed).
const hw2 = blk: {
    var out: [2 * 4 * 4 + 2]u16 = undefined;
    var i: usize = 0;
    for (0..2) |u| {
        for (0..4) |op2| {
            for ([_]u16{ 0x002, 0xC0C, 0x10C, 0xB03 }) |rd_rm| {
                out[i] = 0xF000 | (@as(u16, u) << 6) | (@as(u16, op2) << 4) | rd_rm;
                i += 1;
            }
        }
    }
    out[i] = 0xFD02;
    out[i + 1] = 0xF082;
    break :blk out;
};

test "the parallel adds and subtracts match their parity digests" {
    try parity.expectWideGroupMatches("parallel", 0xFF80, 0xFA80, &hw2);
}
