//! Covers src/core/cpu/text/imm_logic.zig against Capstone.
const capstone = @import("capstone.zig");
const samples = @import("imm_samples.zig");

test "imm_logic prints the way Capstone does over every hw1 and sampled hw2" {
    try capstone.expectWideGroupMatches("imm_logic", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
