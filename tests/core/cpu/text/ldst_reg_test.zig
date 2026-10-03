//! Covers src/core/cpu/text/ldst_reg.zig against Capstone.
const capstone = @import("capstone.zig");

test "every 16-bit ldst_reg encoding prints the way Capstone does" {
    try capstone.expectGroupMatches("ldst_reg");
}
