const std = @import("std");
const builtin = @import("builtin");
const afd = @import("ra8").host.sock.afd;
const ready = @import("ra8").host.sock.ready;
const io = std.testing.io;

test "AFD receive timeouts drain requests before stack buffers are reused" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(afd.PollInfo));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(afd.PollInfo, "handles"));
    var listener = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    defer listener.deinit(io);
    const client = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    try std.testing.expect((try ready.wait(io, listener.socket.handle, 1000)).any());
    const peer = try listener.accept(io);
    defer peer.close(io);
    for (0..32) |_| {
        var buffer: [1]u8 = .{0x55};
        try std.testing.expectError(error.Timeout, afd.receive(io, peer.socket.handle, &buffer, false, .{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } }));
        try std.testing.expectEqual(@as(u8, 0x55), buffer[0]);
        try ready.sendAll(io, client.socket.handle, "x", 1000);
        try std.testing.expect((try ready.wait(io, peer.socket.handle, 1000)).readable);
        try std.testing.expectEqual(@as(usize, 1), try afd.receive(io, peer.socket.handle, &buffer, false, .{ .duration = .{ .raw = .fromMilliseconds(1000), .clock = .awake } }));
        try std.testing.expectEqual(@as(u8, 'x'), buffer[0]);
    }
}

test "AFD reports peer reset after a close with unread data" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var listener = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    defer listener.deinit(io);
    const client = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    try std.testing.expect((try ready.wait(io, listener.socket.handle, 1000)).any());
    const peer = try listener.accept(io);
    try ready.sendAll(io, client.socket.handle, "unread", 1000);
    try std.testing.expect((try ready.wait(io, peer.socket.handle, 1000)).readable);
    peer.close(io);
    var buffer: [1]u8 = undefined;
    try std.testing.expectError(error.ConnectionReset, afd.receive(io, client.socket.handle, &buffer, false, .{ .duration = .{ .raw = .fromMilliseconds(1000), .clock = .awake } }));
}

test "native partial send progresses through the host send loop without changing payload bytes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var listener = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    defer listener.deinit(io);
    const client = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    try std.testing.expect((try ready.wait(io, listener.socket.handle, 1000)).any());
    const peer = try listener.accept(io);
    defer peer.close(io);
    const sent = try std.testing.allocator.alloc(u8, 200_003);
    defer std.testing.allocator.free(sent);
    const received = try std.testing.allocator.alloc(u8, sent.len);
    defer std.testing.allocator.free(received);
    for (sent, 0..) |*byte, index| byte.* = @truncate(index * 31 + 17);
    const timeout = (std.Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(2000), .clock = .awake } }).toDeadline(io);
    const wrote = try afd.send(io, client.socket.handle, sent, timeout);
    try std.testing.expect(wrote > 0 and wrote < sent.len);
    try ready.sendAll(io, client.socket.handle, sent[wrote..], 2000);
    var at: usize = 0;
    while (at < received.len) {
        const got = try afd.receive(io, peer.socket.handle, received[at..], false, timeout);
        try std.testing.expect(got > 0);
        at += got;
    }
    try std.testing.expectEqualSlices(u8, sent, received);
    try std.testing.expect(!(try ready.wait(io, peer.socket.handle, 0)).any());
    std.debug.print("native partial progress: first{d}/{d}, exact received{d}bytes\n", .{ wrote, sent.len, at });
}
