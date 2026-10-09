//! Covers src/chip/core/cpu/text/reverse.zig against its parity digest.
const parity = @import("parity.zig");

test "every reverse encoding matches its parity digest" {
    try parity.expectGroupMatches("reverse");
}
