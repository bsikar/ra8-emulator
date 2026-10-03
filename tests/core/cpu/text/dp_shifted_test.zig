//! Covers src/core/cpu/text/dp_shifted.zig against Capstone.
const capstone = @import("capstone.zig");
const samples = @import("dp_shifted_samples.zig");

test "dp_shifted prints the way Capstone does over every hw1 and sampled hw2" {
    try capstone.expectWideGroupMatches("dp_shifted", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
