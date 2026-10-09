//! Covers src/chip/core/cpu/text/preload.zig against its parity digest.
const parity = @import("parity.zig");

/// The imm12 edges, the T2 negative imm8 edges, register offsets with each
/// shift and the SP/PC Rm the group leaves unclaimed, and a few hw2 that are
/// not preloads at all.
const hw2 = [_]u16{
    0xF000, 0xF004, 0xF009, 0xF00A, 0xF0FF, 0xF123, 0xFFFF,
    0xFC00, 0xFC04, 0xFC09, 0xFC0A, 0xFCFF, 0xF001, 0xF012,
    0xF022, 0xF03E, 0xF00D, 0xF00F, 0xFE04, 0xF840, 0xFD04,
};

test "preload matches its parity digest in every form" {
    try parity.expectWideGroupMatches("preload", 0xFE50, 0xF810, &hw2);
}
