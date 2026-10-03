//! Covers src/core/cpu/text/ldst_imm.zig against Capstone.
const capstone = @import("capstone.zig");

test "every 16-bit ldst_imm encoding prints the way Capstone does" {
    try capstone.expectGroupMatches("ldst_imm");
}
