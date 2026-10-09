//! Covers src/chip/core/cpu/text/umaal.zig against its parity digest.
const parity = @import("parity.zig");

/// Every Rm with RdLo/RdHi pairs low, high and swapped, plus RdLo == RdHi,
/// SP or PC in either, and another hw2[7:4] row (all unclaimed).
const hw2 = blk: {
    const pairs = [_]u16{ 0x0100, 0x1000, 0xAB00, 0xBA00, 0xC000, 0x0C00, 0x2200, 0xD000, 0x0F00 };
    var out: [pairs.len * 16 + 1]u16 = undefined;
    var i: usize = 0;
    for (pairs) |pair| {
        for (0..16) |rm| {
            out[i] = pair | 0x0060 | @as(u16, rm);
            i += 1;
        }
    }
    out[i] = 0x0172;
    break :blk out;
};

test "UMAAL matches its parity digest" {
    try parity.expectWideGroupMatches("umaal", 0xFFF0, 0xFBE0, &hw2);
}
