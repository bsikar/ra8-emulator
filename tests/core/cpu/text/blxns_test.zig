//! Covers src/core/cpu/text/blxns.zig against Capstone.
const capstone = @import("capstone.zig");

test "every 16-bit blxns encoding prints the way Capstone does" {
    try capstone.expectGroupMatches("blxns");
}
