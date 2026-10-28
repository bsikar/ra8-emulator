//! Covers src/session/history/touched_pages.zig: the copy of the dirty
//! bitmaps a checkpoint keeps beside its manifest.
const std = @import("std");
const ra8 = @import("ra8");
const touched_pages = ra8.session.history_touched_pages;
const DirtyPages = ra8.session.history_dirty_pages.DirtyPages;

test "a touched set copies the pages the tracker held and is independent after" {
    var dirty = try DirtyPages.init(std.testing.allocator);
    defer dirty.deinit();
    dirty.markDirty(.cpu0_sram, 5);
    dirty.markRangeDirty(.cpu1_dtcm, 4096, 8192);
    var touched = try touched_pages.Touched.fromDirty(std.testing.allocator, 3, &dirty);
    defer touched.deinit();
    dirty.clearAll();

    try std.testing.expectEqual(@as(u32, 3), touched.since);
    try std.testing.expect(touched.isTouched(.{ .space = .cpu0_sram, .page_index = 5 }));
    try std.testing.expect(touched.isTouched(.{ .space = .cpu1_dtcm, .page_index = 1 }));
    try std.testing.expect(touched.isTouched(.{ .space = .cpu1_dtcm, .page_index = 2 }));
    try std.testing.expect(!touched.isTouched(.{ .space = .cpu1_dtcm, .page_index = 3 }));
    try std.testing.expect(!touched.isTouched(.{ .space = .cpu0_sram, .page_index = 6 }));
}

test "a page past the bitmap is untouched and a space the tracker ignores is unknown" {
    var dirty = try DirtyPages.init(std.testing.allocator);
    defer dirty.deinit();
    var touched = try touched_pages.Touched.fromDirty(std.testing.allocator, 0, &dirty);
    defer touched.deinit();
    try std.testing.expect(!touched.isTouched(.{ .space = .cpu0_sram, .page_index = 1_000_000 }));
    try std.testing.expect(touched.isTouched(.{ .space = .run_state, .page_index = 0 }));
}
