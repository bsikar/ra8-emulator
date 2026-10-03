//! Covers src/core/cpu/text/dp_reg.zig against Capstone.
const capstone = @import("capstone.zig");

test "every dp_reg encoding prints the way Capstone does" {
    try capstone.expectGroupMatches("dp_reg");
}
