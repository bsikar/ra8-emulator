//! Covers src/chip/core/cpu/text/cbz.zig against its parity digest.
const parity = @import("parity.zig");

test "every 16-bit cbz encoding matches its parity digest" {
    try parity.expectGroupMatches("cbz");
}
