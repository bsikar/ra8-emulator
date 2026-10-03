//! Covers src/core/cpu/text/ldm_stm.zig against Capstone.
const capstone = @import("capstone.zig");

test "every 16-bit ldm_stm encoding prints the way Capstone does" {
    try capstone.expectGroupMatches("ldm_stm");
}
