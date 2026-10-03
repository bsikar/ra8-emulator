//! Covers src/core/cpu/text/long_mul.zig against Capstone.
const capstone = @import("capstone.zig");
const samples = @import("multiply_samples.zig");

test "long_mul prints the way Capstone does over every hw1 and sampled hw2" {
    try capstone.expectWideGroupMatches("long_mul", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
