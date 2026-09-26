//! The far end's queues: bounded, in order, and pushing back.
const std = @import("std");
const ra8 = @import("ra8");
const peer = ra8.periph.eth_peer;
const desc = ra8.periph.eth_desc;

test "a frame comes back out the way it went in" {
    var link = peer.Link{};
    try std.testing.expect(link.send(&[_]u8{ 1, 2, 3 }));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, link.sent.peek().?);
}

test "frames leave in the order they arrived" {
    var queue = peer.Queue{};
    _ = queue.push(&[_]u8{0xAA});
    _ = queue.push(&[_]u8{ 0xBB, 0xBB });
    try std.testing.expectEqual(@as(u32, 1), queue.waiting().?);
    queue.drop();
    try std.testing.expectEqual(@as(u32, 2), queue.waiting().?);
}

test "a full queue refuses and counts, and keeps what it holds" {
    var queue = peer.Queue{};
    var n: usize = 0;
    while (n < peer.depth) : (n += 1) try std.testing.expect(queue.push(&[_]u8{1}));
    try std.testing.expect(!queue.push(&[_]u8{2}));
    try std.testing.expectEqual(@as(u32, 1), queue.refused);
    try std.testing.expectEqual(peer.depth, queue.count);
}

test "a queue drained below its depth takes frames again" {
    var queue = peer.Queue{};
    var n: usize = 0;
    while (n < peer.depth) : (n += 1) _ = queue.push(&[_]u8{1});
    queue.drop();
    try std.testing.expect(queue.push(&[_]u8{9}));
}

test "the ring wraps rather than running off its end" {
    var queue = peer.Queue{};
    var n: usize = 0;
    while (n < peer.depth * 3) : (n += 1) {
        try std.testing.expect(queue.push(&[_]u8{@intCast(n)}));
        try std.testing.expectEqual(@as(u32, 1), queue.waiting().?);
        queue.drop();
    }
    try std.testing.expectEqual(@as(usize, 0), queue.count);
}

test "an empty frame is not a frame" {
    var queue = peer.Queue{};
    try std.testing.expect(!queue.push(&[_]u8{}));
    try std.testing.expectEqual(@as(u32, 0), queue.taken);
}

test "a frame longer than the marshal buffer is refused" {
    var queue = peer.Queue{};
    const big = [_]u8{0} ** (desc.limits.frame_max + 1);
    try std.testing.expect(!queue.push(&big));
}

test "dropping an empty queue is not an underflow" {
    var queue = peer.Queue{};
    queue.drop();
    try std.testing.expectEqual(@as(usize, 0), queue.count);
    try std.testing.expect(queue.waiting() == null);
}

test "a link with nothing on it is quiet" {
    var link = peer.Link{};
    try std.testing.expect(link.quiet());
    _ = link.offer(&[_]u8{7});
    try std.testing.expect(!link.quiet());
}
