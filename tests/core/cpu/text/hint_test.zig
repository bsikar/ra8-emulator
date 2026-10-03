//! Covers src/core/cpu/text/hint.zig against Capstone.
const capstone = @import("capstone.zig");

test "every 16-bit hint encoding prints the way Capstone does" {
    try capstone.expectGroupMatches("hint");
}

/// Every 32-bit hint number (the PACBTI ones stay unclaimed), plus a nonzero
/// hw2[10:8] (not a hint).
const wide = blk: {
    var out: [257]u16 = undefined;
    for (0..256) |n| out[n] = 0x8000 | @as(u16, n);
    out[256] = 0x8100;
    break :blk out;
};

test "every 32-bit hint encoding prints the way Capstone does" {
    try capstone.expectWideGroupMatches("hint", 0xFFFF, 0xF3AF, &wide);
}
