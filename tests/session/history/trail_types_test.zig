//! Tests for src/session/history/trail_types.zig: a byte record owns its
//! pre-image and frees it (the leak check sees it go).
const std = @import("std");
const ra8 = @import("ra8");
const types = ra8.session.history_trail_types;

test "a byte record frees the pre-image it owns" {
    const gpa = std.testing.allocator;
    var record: types.Bytes = .{
        .base = 0x2000_0000,
        .offset = 4,
        .initiator = .cpu0,
        .source = .{ .core = .{ .core = .cpu0, .slots = 1 } },
        .part = null,
        .pre = try gpa.dupe(u8, &.{ 1, 2, 3 }),
    };
    record.deinit(gpa);
}
