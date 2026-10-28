//! Covers src/session/history/value_bisect.zig: an interval is skippable
//! only when a record names it and no watched page appears in it.
const std = @import("std");
const ra8 = @import("ra8");
const bisect = ra8.session.history_value_bisect;
const DirtyPages = ra8.session.history_dirty_pages.DirtyPages;

const key_a: bisect.PageKey = .{ .space = .cpu0_sram, .page_index = 0 };
const key_b: bisect.PageKey = .{ .space = .cpu0_sram, .page_index = 9 };

fn record(dirty: *DirtyPages, since: u32) !bisect.Touched {
    return bisect.Touched.fromDirty(std.testing.allocator, since, dirty);
}

test "an interval with no watched page written is skippable" {
    var dirty = try DirtyPages.init(std.testing.allocator);
    defer dirty.deinit();
    dirty.markDirty(.cpu0_sram, 4);
    var touched = try record(&dirty, 2);
    defer touched.deinit();
    try std.testing.expect(bisect.untouched(&touched, 2, &.{ key_a, key_b }));
}

test "any watched page written makes the interval replay" {
    var dirty = try DirtyPages.init(std.testing.allocator);
    defer dirty.deinit();
    dirty.markDirty(.cpu0_sram, 9);
    var touched = try record(&dirty, 2);
    defer touched.deinit();
    try std.testing.expect(!bisect.untouched(&touched, 2, &.{ key_a, key_b }));
}

test "a missing record, an empty page list or a record from another checkpoint never skips" {
    var dirty = try DirtyPages.init(std.testing.allocator);
    defer dirty.deinit();
    var touched = try record(&dirty, 2);
    defer touched.deinit();
    try std.testing.expect(!bisect.untouched(null, 2, &.{key_a}));
    try std.testing.expect(!bisect.untouched(&touched, 2, &.{}));
    // The record starts at checkpoint 2 but the interval starts at 1: a
    // checkpoint between was thinned, so the record covers only part of it.
    try std.testing.expect(!bisect.untouched(&touched, 1, &.{key_a}));
}
