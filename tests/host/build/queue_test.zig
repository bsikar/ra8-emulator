const std = @import("std");
const queue = @import("ra8").host.build.queue;

test "build live output queue drops finitely with visible sequence gaps" {
    const q = try std.testing.allocator.create(queue.Queue);
    defer std.testing.allocator.destroy(q);
    q.* = .{};
    for (0..65) |_| q.push(std.testing.io, .stdout, "chunk");
    try std.testing.expect(q.truncated);
    try std.testing.expectEqual(@as(usize, 64), q.count);
    const first = q.pop(std.testing.io).?;
    try std.testing.expectEqual(@as(u64, 1), first.sequence);
    q.push(std.testing.io, .stderr, "after-drop");
    for (0..63) |_| _ = q.pop(std.testing.io);
    try std.testing.expectEqual(@as(u64, 66), q.pop(std.testing.io).?.sequence);
    try std.testing.expect(q.pop(std.testing.io) == null);
}
