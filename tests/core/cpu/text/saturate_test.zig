//! Covers src/core/cpu/text/saturate.zig against Capstone.
const capstone = @import("capstone.zig");
const samples = @import("saturate_samples.zig");

test "saturate prints the way Capstone does over every hw1 and sampled hw2" {
    try capstone.expectWideGroupMatches("saturate", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
