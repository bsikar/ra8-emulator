//! Covers src/core/cpu/text/push_pop.zig against its parity digest.
const parity = @import("parity.zig");

test "every 16-bit push_pop encoding matches its parity digest" {
    try parity.expectGroupMatches("push_pop");
}
