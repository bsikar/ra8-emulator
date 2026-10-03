//! Covers src/core/cpu/text/cbz.zig against Capstone.
const capstone = @import("capstone.zig");

test "every 16-bit cbz encoding prints the way Capstone does" {
    try capstone.expectGroupMatches("cbz");
}
