//! Covers src/core/cpu/text/mul_acc.zig against Capstone.
const capstone = @import("capstone.zig");
const samples = @import("multiply_samples.zig");

test "mul_acc prints the way Capstone does over every hw1 and sampled hw2" {
    try capstone.expectWideGroupMatches("mul_acc", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
