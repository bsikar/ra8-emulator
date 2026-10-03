//! Covers src/core/cpu/text/shift_reg.zig against Capstone.
const capstone = @import("capstone.zig");
const samples = @import("shift_reg_samples.zig");

test "shift_reg prints the way Capstone does over every hw1 and sampled hw2" {
    try capstone.expectWideGroupMatches("shift_reg", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
