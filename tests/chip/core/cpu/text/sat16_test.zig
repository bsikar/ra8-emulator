//! Covers src/chip/core/cpu/text/sat16.zig against its parity digest.
const parity = @import("parity.zig");
const samples = @import("saturate_samples.zig");

test "sat16 matches its parity digest over every hw1 and sampled hw2" {
    try parity.expectWideGroupMatches("sat16", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
