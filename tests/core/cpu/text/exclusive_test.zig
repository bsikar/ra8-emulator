//! Covers src/core/cpu/text/exclusive.zig against Capstone.
const capstone = @import("capstone.zig");

/// The word forms with zero, decimal, hex and largest offsets and a status
/// register; every narrow and acquire/release op3 for loads and stores;
/// SP and PC as Rt or Rd and Rd equal to Rt (unclaimed); and CLREX.
const hw2 = [_]u16{
    0x0F00, 0x0F01, 0x0F03, 0x0FFF, 0x1200, 0x2201, 0x22FF,
    0x1F4F, 0x1F5F, 0x1FCF, 0x1FDF, 0x1FEF, 0x1F42, 0x1F52,
    0x1FC2, 0x1FD2, 0x1FE2, 0xDF00, 0x1D00, 0x1F41, 0x8F2F,
};

test "exclusive prints the way Capstone does for every form" {
    try capstone.expectWideGroupMatches("exclusive", 0xFF60, 0xE840, &hw2);
}

test "clrex prints the way Capstone does" {
    try capstone.expectWideGroupMatches("exclusive", 0xFFFF, 0xF3BF, &hw2);
}
