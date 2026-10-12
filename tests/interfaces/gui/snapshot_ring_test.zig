//! Host tests for the slice-click's snapshot ring (RA8EMU-838): stamps are
//! kept with their paths, a full ring evicts the oldest whole entry, the
//! newest at or before a time wins, and paths the ring did not write carry
//! no stamp.
const std = @import("std");
const gui_app = @import("gui_app");
const ring_mod = gui_app.snapshot_ring;

const allocator = std.testing.allocator;

test "take keeps stamps with their paths" {
    var ring = ring_mod.Ring.init(allocator);
    defer ring.deinit();
    try ring.take(500, "/tmp/a");
    try ring.take(900, "/tmp/b");
    try std.testing.expectEqual(@as(usize, 2), ring.entries.items.len);
    const one = ring.atOrBefore(600) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 500), one.ns);
    try std.testing.expectEqualStrings("/tmp/a", one.path);
}

test "a full ring evicts the oldest whole entry" {
    var ring = ring_mod.Ring.init(allocator);
    defer ring.deinit();
    for (0..ring_mod.capacity + 3) |index| {
        const path = try std.fmt.allocPrint(allocator, "/tmp/{d}", .{index});
        defer allocator.free(path);
        try ring.take(@intCast(index * 100), path);
    }
    try std.testing.expectEqual(@as(usize, ring_mod.capacity), ring.entries.items.len);
    try std.testing.expectEqual(@as(u64, 300), ring.entries.items[0].ns);
}

test "the newest at or before a time wins" {
    var ring = ring_mod.Ring.init(allocator);
    defer ring.deinit();
    try ring.take(300, "/tmp/a");
    try ring.take(700, "/tmp/b");
    const one = ring.atOrBefore(1000) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 700), one.ns);
}

test "an empty ring keeps nothing this far back" {
    var ring = ring_mod.Ring.init(allocator);
    defer ring.deinit();
    try std.testing.expect(ring.atOrBefore(1000) == null);
    try ring.take(2000, "/tmp/a");
    try std.testing.expect(ring.atOrBefore(1000) == null);
}

test "path names carry their stamp" {
    const path = try ring_mod.name(allocator, "/tmp/snap", 1234);
    defer allocator.free(path);
    try std.testing.expectEqual(@as(u64, 1234), ring_mod.stampOf(path) orelse return error.TestUnexpectedResult);
    try std.testing.expect(ring_mod.stampOf("/tmp/other") == null);
    try std.testing.expect(ring_mod.stampOf("/tmp/snap/notanumber.ra8run") == null);
}
