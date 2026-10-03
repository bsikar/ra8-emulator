//! Covers src/core/cpu/text/ldr_literal.zig against Capstone.
const capstone = @import("capstone.zig");

test "every 16-bit ldr_literal encoding prints the way Capstone does" {
    try capstone.expectGroupMatches("ldr_literal");
}
