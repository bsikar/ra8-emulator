//! Covers src/chip/core/cpu/text/sat_arith.zig against its parity digest.
const parity = @import("parity.zig");
const samples = @import("sat_arith_samples.zig");

test "sat_arith matches its parity digest over every hw1 and sampled hw2" {
    try parity.expectWideGroupMatches("sat_arith", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
