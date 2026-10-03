//! Covers src/core/cpu/text/acq_rel.zig against Capstone.
const capstone = @import("capstone.zig");

/// Every size for a low and a high Rt, the reserved size (unclaimed), and
/// SP or PC as Rt (unclaimed).
const hw2 = [_]u16{
    0x0F8F, 0x0F9F, 0x0FAF, 0xCF8F, 0xCF9F, 0xCFAF,
    0x0FBF, 0xDF8F, 0xFFAF, 0xEFAF,
};

test "acq_rel prints the way Capstone does for every size" {
    try capstone.expectWideGroupMatches("acq_rel", 0xFFE0, 0xE8C0, &hw2);
}
