//! Covers src/core/cpu/memory/store.zig.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.core.memmap;
const Store = ra8.core.cpu.memory.store.Store;

test "every region is backed, and comes up zeroed" {
    var store = try Store.init(null);
    defer store.deinit();
    for (memmap.ram) |region| {
        const bytes = store.region(region.base).?;
        try std.testing.expectEqual(@as(usize, region.size), bytes.len);
        try std.testing.expectEqual(@as(u8, 0), bytes[0]);
        try std.testing.expectEqual(@as(u8, 0), bytes[bytes.len - 1]);
    }
}

test "a Non-secure view is the same bytes as its Secure region" {
    var store = try Store.init(null);
    defer store.deinit();
    store.span(memmap.sram_base + 0x200, 1).?[0] = 0x5A;
    try std.testing.expectEqual(@as(u8, 0x5A), store.span(memmap.ns_sram_base + 0x200, 1).?[0]);
    store.span(memmap.ns_sdram_base + 4, 1).?[0] = 0xA5;
    try std.testing.expectEqual(@as(u8, 0xA5), store.span(memmap.sdram_base + 4, 1).?[0]);
    store.span(memmap.mram_base + 8, 1).?[0] = 0x3C;
    try std.testing.expectEqual(@as(u8, 0x3C), store.span(memmap.ns_mram_base + 8, 1).?[0]);
}

test "a second core borrows the shared SRAM and keeps its own MRAM, TCMs and PPB" {
    var first = try Store.init(null);
    defer first.deinit();
    var second = try Store.init(&first);
    defer second.deinit();
    first.span(memmap.sram_base, 1).?[0] = 0x11;
    try std.testing.expectEqual(@as(u8, 0x11), second.span(memmap.ns_sram_base, 1).?[0]);
    try std.testing.expectEqual(first.region(memmap.sdram_base).?.ptr, second.region(memmap.sdram_base).?.ptr);
    for ([_]u32{ memmap.mram_base, memmap.itcm_base, memmap.dtcm_base, memmap.ppb_base }) |base| {
        try std.testing.expect(first.region(base).?.ptr != second.region(base).?.ptr);
    }
}

test "a borrower's deinit leaves the lender's pages alone" {
    var first = try Store.init(null);
    defer first.deinit();
    var second = try Store.init(&first);
    second.deinit();
    first.span(memmap.sram_base, 1).?[0] = 0x22;
    try std.testing.expectEqual(@as(u8, 0x22), first.span(memmap.ns_sram_base, 1).?[0]);
}

test "a span outside every region, or across a region's end, is refused" {
    var store = try Store.init(null);
    defer store.deinit();
    try std.testing.expect(store.span(0x4000_0000, 4) == null);
    try std.testing.expect(store.span(memmap.sram_end - 2, 4) == null);
    try std.testing.expect(store.span(memmap.sram_end - 4, 4) != null);
    try std.testing.expect(store.region(0x4000_0000) == null);
}

test "a store maps a window outside memmap and refuses one inside a region" {
    var store = try Store.init(null);
    defer store.deinit();
    try store.map(0x02C1_E000, 0x1000);
    try std.testing.expect(store.span(0x02C1_EDA0, 8) != null);
    try std.testing.expectError(error.Mapped, store.map(0x02C1_E000, 0x1000));
    try std.testing.expectError(error.Mapped, store.map(memmap.sram_base, 0x1000));
}
