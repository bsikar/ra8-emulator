//! Tests for src/core/board_ram.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.core.board_ram;
const memmap = ra8.core.memmap;

test "covers answers for the board's regions and nothing else" {
    try std.testing.expect(mod.covers(memmap.sram_base, 4));
    try std.testing.expect(mod.covers(memmap.ns_sram_base, 4));
    try std.testing.expect(mod.covers(memmap.ppb_base, 4));
    // The whole code MRAM is the board's, so a page an image never loads
    // still answers.
    try std.testing.expect(mod.covers(memmap.mram_base + 0x8_1000, 4));
    try std.testing.expect(!mod.covers(memmap.mram_end - 2, 4));
    // A span running off the end of a region is not covered by it.
    try std.testing.expect(!mod.covers(memmap.sram_end - 2, 4));
}
