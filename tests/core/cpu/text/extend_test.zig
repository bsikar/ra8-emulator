//! Covers src/core/cpu/text/extend.zig against Capstone.
const capstone = @import("capstone.zig");

test "every extend encoding prints the way Capstone does" {
    try capstone.expectGroupMatches("extend");
}
