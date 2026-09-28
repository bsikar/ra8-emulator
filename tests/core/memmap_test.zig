//! Tests for src/core/memmap.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.core.memmap;

const dwt = mod.dwt;
const nvic = mod.nvic;
const ppb_base = mod.ppb_base;
const ppb_size = mod.ppb_size;
const masterHolds = mod.masterHolds;
const ram = mod.ram;
const scb = mod.scb;
const syst = mod.syst;
test "every named PPB register falls inside the PPB window" {
    inline for (.{ scb, syst, nvic, dwt }) |block| {
        inline for (@typeInfo(block).@"struct".decls) |decl| {
            const address = @field(block, decl.name);
            try std.testing.expect(address >= ppb_base);
            try std.testing.expect(address < ppb_base + ppb_size);
        }
    }
}

test "the PPB does not overlap the peripheral window" {
    try std.testing.expect(ppb_base > 0x4000_0000 + 0x1000_0000);
}

test "regions are ordered, non-overlapping and page aligned" {
    var previous_end: u64 = 0;
    for (ram) |region| {
        try std.testing.expect(region.base >= previous_end);
        try std.testing.expectEqual(@as(u32, 0), region.base % 0x1000);
        try std.testing.expectEqual(@as(u32, 0), region.size % 0x1000);
        previous_end = region.end();
    }
}

test "a bus master reaches the SRAM and both SDRAM aliases" {
    try std.testing.expect(masterHolds(mod.sram_base, 4));
    try std.testing.expect(masterHolds(mod.sram_end - 4, 4));
    try std.testing.expect(masterHolds(mod.sdram_base, 4));
    try std.testing.expect(masterHolds(mod.sdram_end - 4, 4));
    try std.testing.expect(masterHolds(mod.ns_sdram_base, 4));
    try std.testing.expect(masterHolds(mod.ns_sdram_end - 4, 4));
}

test "a bus master does not reach the core's own TCM" {
    try std.testing.expect(!masterHolds(mod.dtcm_base, 4));
    try std.testing.expect(!masterHolds(mod.dtcm_end - 4, 4));
}

test "the peripheral window and the PPB are not somewhere a frame lives" {
    try std.testing.expect(!masterHolds(0x4000_0000, 4));
    try std.testing.expect(!masterHolds(mod.ppb_base, 4));
}

test "a span that runs off the end of a window is not held by it" {
    try std.testing.expect(!masterHolds(mod.sram_end - 2, 4));
    try std.testing.expect(!masterHolds(mod.sdram_end - 2, 4));
    try std.testing.expect(!masterHolds(0xFFFF_FFFC, 8));
}

test "an empty span is nowhere" {
    try std.testing.expect(!masterHolds(mod.sram_base, 0));
}

test "the window a bus master address sits in comes back whole" {
    try std.testing.expectEqual(mod.sram_end, mod.masterWindow(mod.sram_base).?.end);
    try std.testing.expectEqual(mod.sram_base, mod.masterWindow(mod.sram_end - 1).?.base);
    try std.testing.expectEqual(mod.sdram_end, mod.masterWindow(mod.sdram_base).?.end);
    try std.testing.expectEqual(mod.ns_sdram_end, mod.masterWindow(mod.ns_sdram_base).?.end);
}

test "an address in no master window sits in none" {
    try std.testing.expect(mod.masterWindow(mod.dtcm_base) == null);
    try std.testing.expect(mod.masterWindow(mod.sram_end) == null);
    try std.testing.expect(mod.masterWindow(mod.sdram_end) == null);
    try std.testing.expect(mod.masterWindow(0x4000_0000) == null);
}

test "the debug window list carries the DTCM the master list leaves out" {
    try std.testing.expect(mod.debugHolds(mod.dtcm_base, 16));
    try std.testing.expect(!masterHolds(mod.dtcm_base, 16));
}

test "the debug window list carries every RAM the loader maps" {
    try std.testing.expect(mod.debugHolds(mod.sram_base, 16));
    try std.testing.expect(mod.debugHolds(mod.sdram_base, 16));
    try std.testing.expect(mod.debugHolds(mod.ns_sdram_base, 16));
}

test "the debug window list stops at the peripheral bus" {
    try std.testing.expect(!mod.debugHolds(0x4000_0000, 4));
    try std.testing.expect(!mod.debugHolds(ppb_base, 4));
}
