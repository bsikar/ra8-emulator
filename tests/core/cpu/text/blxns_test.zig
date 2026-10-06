//! Covers src/core/cpu/text/blxns.zig against its parity digest.
const parity = @import("parity.zig");

test "every 16-bit blxns encoding matches its parity digest" {
    try parity.expectGroupMatches("blxns");
}
