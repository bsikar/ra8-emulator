//! Covers src/core/cpu/text/mov_wide.zig against Capstone.
const capstone = @import("capstone.zig");
const samples = @import("wide_imm_samples.zig");

test "mov_wide prints the way Capstone does over every hw1 and sampled hw2" {
    try capstone.expectWideGroupMatches("mov_wide", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
