//! Covers src/core/cpu/text/svc.zig against Capstone.
const capstone = @import("capstone.zig");

test "every 16-bit svc encoding prints the way Capstone does" {
    try capstone.expectGroupMatches("svc");
}
