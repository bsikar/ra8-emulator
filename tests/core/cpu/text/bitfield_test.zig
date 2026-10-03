//! Covers src/core/cpu/text/bitfield.zig against Capstone.
const capstone = @import("capstone.zig");
const samples = @import("bitfield_samples.zig");

test "bitfield prints the way Capstone does over every hw1 and sampled hw2" {
    try capstone.expectWideGroupMatches("bitfield", samples.hw1_mask, samples.hw1_value, &samples.hw2);
}
