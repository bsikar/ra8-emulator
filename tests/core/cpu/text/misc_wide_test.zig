//! Covers src/core/cpu/text/misc_wide.zig against Capstone.
const capstone = @import("capstone.zig");

/// Every op2 for each Rm copy 0 to 15, with Rd r0, r12 and SP (unclaimed).
const hw2 = blk: {
    var out: [4 * 16 * 3]u16 = undefined;
    var i: usize = 0;
    for ([_]u16{ 0xF080, 0xF090, 0xF0A0, 0xF0B0 }) |op2| {
        for (0..16) |rm| {
            for ([_]u16{ 0x000, 0xC00, 0xD00 }) |rd| {
                out[i] = op2 | rd | @as(u16, rm);
                i += 1;
            }
        }
    }
    break :blk out;
};

test "REV, REV16, RBIT and REVSH print the way Capstone does" {
    try capstone.expectWideGroupMatches("misc_wide", 0xFFF0, 0xFA90, &hw2);
}

test "CLZ prints the way Capstone does" {
    try capstone.expectWideGroupMatches("misc_wide", 0xFFF0, 0xFAB0, &hw2);
}
