//! Covers src/core/cpu/text/push_pop.zig against Capstone.
const capstone = @import("capstone.zig");

test "every 16-bit push_pop encoding prints the way Capstone does" {
    try capstone.expectGroupMatches("push_pop");
}
