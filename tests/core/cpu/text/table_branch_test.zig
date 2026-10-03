//! Covers src/core/cpu/text/table_branch.zig against Capstone.
const capstone = @import("capstone.zig");

/// TBB and TBH for a low and a high Rm, plus SP or PC as Rm (unclaimed).
const hw2 = [_]u16{ 0xF000, 0xF00E, 0xF010, 0xF01C, 0xF00D, 0xF01F };

test "table_branch prints the way Capstone does for every Rn" {
    try capstone.expectWideGroupMatches("table_branch", 0xFFF0, 0xE8D0, &hw2);
}
