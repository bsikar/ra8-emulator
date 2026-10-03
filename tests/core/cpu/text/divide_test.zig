//! Covers src/core/cpu/text/divide.zig against Capstone.
const capstone = @import("capstone.zig");
const samples = @import("divide_samples.zig");

test "divide prints the way Capstone does over every hw1 and sampled hw2" {
    try capstone.expectWideGroupMatches("divide", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
