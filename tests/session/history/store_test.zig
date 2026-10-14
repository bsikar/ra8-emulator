//! Covers src/session/history/store.zig: the hot tier's bounded queue of
//! whole frames, its eviction from the front, and its rewind cut.
const std = @import("std");
const ra8 = @import("ra8");
const store_mod = ra8.session.history_store;
const format = ra8.session.history_format;

fn frameOf(tag: u8) [11]u8 {
    var raw: [11]u8 = undefined;
    std.mem.writeInt(u32, raw[0..4], 1, .little);
    std.mem.writeInt(u16, raw[4..6], 1, .little);
    std.mem.writeInt(u32, raw[6..10], format.crcOf(1, &.{tag}), .little);
    raw[10] = tag;
    return raw;
}

test "frames come back out in the order they went in" {
    var store = try store_mod.Store.init(std.testing.allocator, 64);
    defer store.deinit();
    const a = frameOf(1);
    const b = frameOf(2);
    try store.append(&a);
    try store.append(&b);
    try std.testing.expectEqual(@as(usize, 2), store.count());
    try std.testing.expectEqualSlices(u8, &a, store.frame(0));
    try std.testing.expectEqualSlices(u8, &b, store.frame(1));
    try std.testing.expectEqual(@as(usize, 42), store.capacity() - store.held);
}

test "the oldest whole frames make room, and the queue never splits one" {
    var store = try store_mod.Store.init(std.testing.allocator, 33);
    defer store.deinit();
    for (0..6) |i| {
        const raw = frameOf(@intCast(i));
        try store.append(&raw);
    }
    // Six 11-byte frames do not fit in 33 bytes; the three newest do.
    try std.testing.expectEqual(@as(usize, 3), store.count());
    for (0..3) |i| {
        const decoded = try format.decode(store.frame(i));
        try std.testing.expectEqual(@as(u8, @intCast(i + 3)), decoded.frame.payload[0]);
    }
}

test "a frame larger than the whole queue is refused, not half-kept" {
    var store = try store_mod.Store.init(std.testing.allocator, 32);
    defer store.deinit();
    const one = frameOf(1);
    try store.append(&one);
    var too_big: [33]u8 = undefined;
    @memset(&too_big, 0);
    std.mem.writeInt(u32, too_big[0..4], 23, .little);
    try std.testing.expectError(store_mod.Store.Error.FrameTooBig, store.append(&too_big));
    try std.testing.expectEqual(@as(usize, 1), store.count());
    try std.testing.expectEqualSlices(u8, &one, store.frame(0));
}

test "keeping the front frames is how a rewind drops what it rewrites" {
    var store = try store_mod.Store.init(std.testing.allocator, 64);
    defer store.deinit();
    for (0..3) |i| {
        const raw = frameOf(@intCast(10 + i));
        try store.append(&raw);
    }
    store.keepFrames(2);
    try std.testing.expectEqual(@as(usize, 2), store.count());
    const decoded = try format.decode(store.frame(1));
    try std.testing.expectEqual(@as(u8, 11), decoded.frame.payload[0]);
    store.clear();
    try std.testing.expectEqual(@as(usize, 0), store.count());
}
