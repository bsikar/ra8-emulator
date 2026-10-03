//! Covers src/core/cpu/text/reverse.zig against Capstone.
const capstone = @import("capstone.zig");

test "every reverse encoding prints the way Capstone does" {
    try capstone.expectGroupMatches("reverse");
}
