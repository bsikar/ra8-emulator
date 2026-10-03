//! Covers src/core/cpu/text/sp_arith.zig against Capstone.
const capstone = @import("capstone.zig");

test "every 16-bit sp_arith encoding prints the way Capstone does" {
    try capstone.expectGroupMatches("sp_arith");
}
