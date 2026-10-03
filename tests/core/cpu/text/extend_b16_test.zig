//! Covers src/core/cpu/text/extend_b16.zig against Capstone.
const capstone = @import("capstone.zig");
const samples = @import("extend_samples.zig");

test "extend_b16 prints the way Capstone does over every hw1 and sampled hw2" {
    try capstone.expectWideGroupMatches("extend_b16", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
