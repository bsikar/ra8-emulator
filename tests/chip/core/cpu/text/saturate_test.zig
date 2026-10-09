//! Covers src/chip/core/cpu/text/saturate.zig against its parity digest.
const parity = @import("parity.zig");
const samples = @import("saturate_samples.zig");

test "saturate matches its parity digest over every hw1 and sampled hw2" {
    try parity.expectWideGroupMatches("saturate", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
