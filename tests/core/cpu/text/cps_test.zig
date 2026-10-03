//! Covers src/core/cpu/text/cps.zig against Capstone.
const capstone = @import("capstone.zig");

test "every 16-bit cps encoding prints the way Capstone does" {
    try capstone.expectGroupMatches("cps");
}
