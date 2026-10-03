//! Covers src/core/cpu/text/sat_arith.zig against Capstone.
const capstone = @import("capstone.zig");
const samples = @import("sat_arith_samples.zig");

test "sat_arith prints the way Capstone does over every hw1 and sampled hw2" {
    try capstone.expectWideGroupMatches("sat_arith", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
