//! Covers src/core/cpu/text/mov_wide.zig against its parity digest.
const parity = @import("parity.zig");
const samples = @import("wide_imm_samples.zig");

test "mov_wide matches its parity digest over every hw1 and sampled hw2" {
    try parity.expectWideGroupMatches("mov_wide", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
