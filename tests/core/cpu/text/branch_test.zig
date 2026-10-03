//! Covers src/core/cpu/text/branch.zig against Capstone.
const capstone = @import("capstone.zig");

test "every 16-bit branch encoding prints the way Capstone does" {
    try capstone.expectGroupMatches("branch");
}
