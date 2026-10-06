//! Covers src/core/cpu/text/special_data.zig against its parity digest.
const parity = @import("parity.zig");

test "every special_data encoding matches its parity digest" {
    try parity.expectGroupMatches("special_data");
}
