//! Covers src/core/cpu/text/hint.zig against Capstone.
const capstone = @import("capstone.zig");

test "every 16-bit hint encoding prints the way Capstone does" {
    try capstone.expectGroupMatches("hint");
}
