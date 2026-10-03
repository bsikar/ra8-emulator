//! Covers src/core/cpu/text/it.zig against Capstone.
const capstone = @import("capstone.zig");

test "every 16-bit it encoding prints the way Capstone does" {
    try capstone.expectGroupMatches("it");
}
