//! Covers src/core/cpu/text/mul_acc.zig against its parity digest.
const parity = @import("parity.zig");
const samples = @import("multiply_samples.zig");

test "mul_acc matches its parity digest over every hw1 and sampled hw2" {
    try parity.expectWideGroupMatches("mul_acc", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
