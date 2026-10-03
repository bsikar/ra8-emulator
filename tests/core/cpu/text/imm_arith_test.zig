//! Covers src/core/cpu/text/imm_arith.zig against Capstone.
const capstone = @import("capstone.zig");
const samples = @import("imm_samples.zig");

test "imm_arith prints the way Capstone does over every hw1 and sampled hw2" {
    try capstone.expectWideGroupMatches("imm_arith", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
