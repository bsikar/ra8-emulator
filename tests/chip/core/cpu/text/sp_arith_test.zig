//! Covers src/chip/core/cpu/text/sp_arith.zig against its parity digest.
const parity = @import("parity.zig");

test "every 16-bit sp_arith encoding matches its parity digest" {
    try parity.expectGroupMatches("sp_arith");
}
