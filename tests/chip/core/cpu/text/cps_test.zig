//! Covers src/chip/core/cpu/text/cps.zig against its parity digest.
const parity = @import("parity.zig");

test "every 16-bit cps encoding matches its parity digest" {
    try parity.expectGroupMatches("cps");
}
