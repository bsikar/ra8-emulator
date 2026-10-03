//! Covers src/core/cpu/text/sel.zig against Capstone.
const capstone = @import("capstone.zig");

/// Every Rm with Rd r0, r12 and SP (unclaimed), plus a set hw2[4] (unclaimed).
const hw2 = blk: {
    var out: [16 * 3 + 1]u16 = undefined;
    var i: usize = 0;
    for (0..16) |rm| {
        for ([_]u16{ 0x000, 0xC00, 0xD00 }) |rd| {
            out[i] = 0xF080 | rd | @as(u16, rm);
            i += 1;
        }
    }
    out[i] = 0xF092;
    break :blk out;
};

test "SEL prints the way Capstone does" {
    try capstone.expectWideGroupMatches("sel", 0xFFF0, 0xFAA0, &hw2);
}
