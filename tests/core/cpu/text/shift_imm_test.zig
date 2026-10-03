//! Covers src/core/cpu/text/shift_imm.zig against Capstone.
const capstone = @import("capstone.zig");

test "every shift_imm encoding prints the way Capstone does" {
    try capstone.expectGroupMatches("shift_imm");
}
