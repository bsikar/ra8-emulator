//! Covers src/core/cpu/text/sat16.zig against Capstone.
const capstone = @import("capstone.zig");
const samples = @import("saturate_samples.zig");

test "sat16 prints the way Capstone does over every hw1 and sampled hw2" {
    try capstone.expectWideGroupMatches("sat16", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
