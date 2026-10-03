//! Covers src/core/cpu/text/add_sub.zig against Capstone.
const capstone = @import("capstone.zig");

test "every add_sub encoding prints the way Capstone does" {
    try capstone.expectGroupMatches("add_sub");
}
