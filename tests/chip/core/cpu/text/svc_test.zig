//! Covers src/chip/core/cpu/text/svc.zig against its parity digest.
const parity = @import("parity.zig");

test "every 16-bit svc encoding matches its parity digest" {
    try parity.expectGroupMatches("svc");
}
