//! Tests for DirtyPages bitmap tracking, observer adapters, and barrier handling.
const std = @import("std");
const ra8 = @import("ra8");
const DirtyPages = ra8.session.history_dirty_pages.DirtyPages;
const ComponentNode = ra8.session.history_dirty_pages.ComponentNode;
const memmap = ra8.chip.core.memmap;
const observer_mod = ra8.chip.core.cpu.memory.observer;

test "DirtyPages init, mark, isDirty, clear, and testAndClear" {
    var dirty = try DirtyPages.init(std.testing.allocator);
    defer dirty.deinit();

    try std.testing.expect(!dirty.isDirty(.cpu0_mram, 0));
    try std.testing.expect(!dirty.isDirty(.cpu0_mram, 5));

    dirty.markDirty(.cpu0_mram, 5);
    try std.testing.expect(dirty.isDirty(.cpu0_mram, 5));
    try std.testing.expect(!dirty.isDirty(.cpu0_mram, 4));
    try std.testing.expect(!dirty.isDirty(.cpu0_mram, 6));

    try std.testing.expect(dirty.testAndClear(.cpu0_mram, 5));
    try std.testing.expect(!dirty.isDirty(.cpu0_mram, 5));
    try std.testing.expect(!dirty.testAndClear(.cpu0_mram, 5));
}

test "DirtyPages markRangeDirty spans across page boundaries" {
    var dirty = try DirtyPages.init(std.testing.allocator);
    defer dirty.deinit();

    // Mark 4000 to 8200: covers page 0, page 1, and page 2.
    dirty.markRangeDirty(.cpu0_sram, 4000, 4200);
    try std.testing.expect(dirty.isDirty(.cpu0_sram, 0));
    try std.testing.expect(dirty.isDirty(.cpu0_sram, 1));
    try std.testing.expect(dirty.isDirty(.cpu0_sram, 2));
    try std.testing.expect(!dirty.isDirty(.cpu0_sram, 3));
    try std.testing.expectEqual(@as(usize, 3), dirty.dirtyCount(.cpu0_sram));
}

test "DirtyPages ensureCapacity expands for large page index" {
    var dirty = try DirtyPages.init(std.testing.allocator);
    defer dirty.deinit();

    // Page 20000 requires 313 u64 words
    dirty.markDirty(.sd_card, 20000);
    try std.testing.expect(dirty.isDirty(.sd_card, 20000));
    try std.testing.expect(!dirty.isDirty(.sd_card, 19999));
    try std.testing.expect(dirty.testAndClear(.sd_card, 20000));
    try std.testing.expect(!dirty.isDirty(.sd_card, 20000));
}

test "DirtyPages storeObserver routes memory regions and initiators" {
    var dirty = try DirtyPages.init(std.testing.allocator);
    defer dirty.deinit();

    const obs = dirty.storeObserver();
    var pre: [4]u8 = @splat(0);

    // CPU0 MRAM write
    obs.bytes(.{ .base = memmap.mram_base, .offset = 0x2000, .initiator = .cpu0, .pre = &pre });
    try std.testing.expect(dirty.isDirty(.cpu0_mram, 2));
    try std.testing.expect(!dirty.isDirty(.cpu1_mram, 2));

    // CPU1 MRAM write
    obs.bytes(.{ .base = memmap.mram_base, .offset = 0x3000, .initiator = .cpu1, .pre = &pre });
    try std.testing.expect(dirty.isDirty(.cpu1_mram, 3));

    // CPU0 DTCM vs CPU1 DTCM
    obs.bytes(.{ .base = memmap.dtcm_base, .offset = 0x1000, .initiator = .cpu0, .pre = &pre });
    obs.bytes(.{ .base = memmap.dtcm_base, .offset = 0x4000, .initiator = .cpu1, .pre = &pre });
    try std.testing.expect(dirty.isDirty(.cpu0_dtcm, 1));
    try std.testing.expect(dirty.isDirty(.cpu1_dtcm, 4));

    // Non-secure alias for SRAM
    obs.bytes(.{ .base = memmap.ns_sram_base, .offset = 0x5000, .initiator = .cpu0, .pre = &pre });
    try std.testing.expect(dirty.isDirty(.cpu0_sram, 5));
}

test "DirtyPages barrier handling marks expected spaces" {
    var dirty = try DirtyPages.init(std.testing.allocator);
    defer dirty.deinit();

    const obs = dirty.storeObserver();

    // Attach external marks SDRAM dirty
    obs.barrier(.attach_external);
    try std.testing.expect(dirty.isDirty(.cpu0_sdram, 0));
    try std.testing.expect(!dirty.isDirty(.cpu0_sram, 0));

    dirty.clearAll();
    try std.testing.expect(!dirty.isDirty(.cpu0_sdram, 0));

    // Wipe marks all spaces dirty
    obs.barrier(.wipe);
    try std.testing.expect(dirty.isDirty(.cpu0_mram, 0));
    try std.testing.expect(dirty.isDirty(.cpu0_sram, 0));
    try std.testing.expect(dirty.isDirty(.cpu1_dtcm, 0));
    try std.testing.expect(dirty.isDirty(.sd_card, 0));
}

test "DirtyPages componentObserver marks component spaces" {
    var dirty = try DirtyPages.init(std.testing.allocator);
    defer dirty.deinit();

    var nor_node: ComponentNode = .{ .dirty = &dirty, .space = .nor_flash };
    const nor_obs = dirty.componentObserver(&nor_node);
    var pre: [16]u8 = @splat(0xFF);

    nor_obs.bytes(.{ .base = 0, .offset = 0x8000, .initiator = .none, .pre = &pre });
    try std.testing.expect(dirty.isDirty(.nor_flash, 8));
    try std.testing.expect(!dirty.isDirty(.nor_flash, 7));

    var dummy: u8 = 0;
    nor_obs.barrier(.{ .component = .{ .owner = &dummy, .what = .reset } });
    try std.testing.expect(dirty.isDirty(.nor_flash, 0));
    try std.testing.expect(dirty.isDirty(.nor_flash, 100));
}

fn testDirtyPagesInitAllocFailure(allocator: std.mem.Allocator) !void {
    var dp = try DirtyPages.init(allocator);
    defer dp.deinit();
}

test "DirtyPages init cleans up allocated masks on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testDirtyPagesInitAllocFailure, .{});
}
