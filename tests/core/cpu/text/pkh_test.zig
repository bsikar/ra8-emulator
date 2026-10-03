//! Covers src/core/cpu/text/pkh.zig against Capstone.
const capstone = @import("capstone.zig");

/// PKHBT and PKHTB with shifts 0, 1, 9, 10, 16 and 31, Rd and Rm low and high,
/// plus SP as Rd, PC as Rm and set hw2[15] or hw2[4] (all unclaimed).
const hw2 = [_]u16{
    0x0002, 0x0022, 0x0042, 0x0062, 0x2042, 0x2062, 0x2082, 0x20A2,
    0x4002, 0x4022, 0x7FC2, 0x7FE2, 0x0C0C, 0x0C2C, 0x3B49, 0x3B69,
    0x0D02, 0x000F, 0x8002, 0x0012,
};

test "PKHBT and PKHTB print the way Capstone does" {
    try capstone.expectWideGroupMatches("pkh", 0xFFF0, 0xEAC0, &hw2);
}
