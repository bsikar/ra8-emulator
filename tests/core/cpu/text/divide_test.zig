//! Covers src/core/cpu/text/divide.zig against its parity digest.
const parity = @import("parity.zig");
const samples = @import("divide_samples.zig");

test "divide matches its parity digest over every hw1 and sampled hw2" {
    try parity.expectWideGroupMatches("divide", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
