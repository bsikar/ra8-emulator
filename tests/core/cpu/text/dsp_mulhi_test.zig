//! Covers src/core/cpu/text/dsp_mulhi.zig against Capstone.
const capstone = @import("capstone.zig");
const samples = @import("dsp_mul_samples.zig");

test "dsp_mulhi prints the way Capstone does over every hw1 and sampled hw2" {
    try capstone.expectWideGroupMatches("dsp_mulhi", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
