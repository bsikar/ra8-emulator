//! Covers src/core/cpu/text/it.zig against its parity digest.
const parity = @import("parity.zig");

test "every 16-bit it encoding matches its parity digest" {
    try parity.expectGroupMatches("it");
}
