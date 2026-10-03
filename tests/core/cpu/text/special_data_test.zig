//! Covers src/core/cpu/text/special_data.zig against Capstone.
const capstone = @import("capstone.zig");

test "every special_data encoding prints the way Capstone does" {
    try capstone.expectGroupMatches("special_data");
}
