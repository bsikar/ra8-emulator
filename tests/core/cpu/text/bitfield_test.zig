//! Covers src/core/cpu/text/bitfield.zig against its parity digest.
const parity = @import("parity.zig");
const samples = @import("bitfield_samples.zig");

test "bitfield matches its parity digest over every hw1 and sampled hw2" {
    try parity.expectWideGroupMatches("bitfield", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
