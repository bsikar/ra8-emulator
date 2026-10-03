//! Covers src/core/cpu/text/dsp_long_mul.zig against Capstone.
const capstone = @import("capstone.zig");
const samples = @import("dsp_mul_samples.zig");

test "dsp_long_mul prints the way Capstone does over every hw1 and sampled hw2" {
    try capstone.expectWideGroupMatches("dsp_long_mul", 0xFFE0, 0xFBC0, &samples.hw2);
}
