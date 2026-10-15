const std = @import("std");
const sock_ready = @import("ra8").host.sock.ready;
const io = std.testing.io;
const builtin = @import("builtin");

fn pair() ![2]std.Io.net.Stream {
    var listener = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    defer listener.deinit(io);
    try std.testing.expect(!(try sock_ready.wait(io, listener.socket.handle, 0)).any());
    const client = try listener.socket.address.connect(io, .{ .mode = .stream });
    errdefer client.close(io);
    try std.testing.expect((try sock_ready.wait(io, listener.socket.handle, 1000)).readable);
    return .{ try listener.accept(io), client };
}

test "native listener and stream idle, data, peek, take and EOF" {
    const streams = try pair();
    defer streams[0].close(io);
    defer streams[1].close(io);
    const fd = streams[0].socket.handle;
    for (0..32) |_| try std.testing.expect(!(try sock_ready.wait(io, fd, 0)).any());
    try sock_ready.sendAll(io, streams[1].socket.handle, "\x03y", 1000);
    try std.testing.expect((try sock_ready.wait(io, fd, 1000)).readable);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 1), sock_ready.takeByte(io, fd, &byte, true));
    try std.testing.expectEqual(@as(u8, 3), byte[0]);
    try std.testing.expectEqual(@as(?usize, 1), sock_ready.takeByte(io, fd, &byte, false));
    try std.testing.expectEqual(@as(u8, 3), byte[0]);
    try streams[1].shutdown(io, .send);
    try std.testing.expect((try sock_ready.wait(io, fd, 1000)).any());
    try std.testing.expectEqual(@as(?usize, 1), sock_ready.takeByte(io, fd, &byte, false));
    try std.testing.expectEqual(@as(u8, 'y'), byte[0]);
    try std.testing.expect((try sock_ready.wait(io, fd, 1000)).any());
    try std.testing.expectEqual(@as(?usize, 0), sock_ready.takeByte(io, fd, &byte, true));
    try sock_ready.sendAll(io, fd, "r", 1000);
    try std.testing.expect((try sock_ready.wait(io, streams[1].socket.handle, 1000)).readable);
    try std.testing.expectEqual(@as(?usize, 1), sock_ready.takeByte(io, streams[1].socket.handle, &byte, false));
    try std.testing.expectEqual(@as(u8, 'r'), byte[0]);
}

test "native streams repeatedly reconnect and close" {
    for (0..16) |_| {
        const streams = try pair();
        defer streams[0].close(io);
        streams[1].close(io);
        try std.testing.expect((try sock_ready.wait(io, streams[0].socket.handle, 1000)).any());
        var byte: [1]u8 = undefined;
        try std.testing.expectEqual(@as(?usize, 0), sock_ready.takeByte(io, streams[0].socket.handle, &byte, false));
    }
}

test "native send to a slow peer has one finite deadline" {
    const streams = try pair();
    defer for (streams) |stream| stream.close(io);
    if (builtin.os.tag != .windows) {
        const size: u32 = 4096;
        try std.posix.setsockopt(streams[0].socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&size));
    }
    const bytes = try std.testing.allocator.alloc(u8, 16 * 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0x65);
    const start = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    var timed_out = false;
    for (0..16) |_| {
        sock_ready.sendAll(io, streams[0].socket.handle, bytes, 20) catch |err| {
            try std.testing.expectEqual(error.Timeout, err);
            timed_out = true;
            break;
        };
    }
    try std.testing.expect(timed_out);
    try std.testing.expect(std.Io.Timestamp.now(io, .awake).toMilliseconds() - start < 2000);
}

test "native send leaves the socket's own blocking mode as it found it" {
    const streams = try pair();
    defer for (streams) |stream| stream.close(io);
    const fd = streams[0].socket.handle;
    if (builtin.os.tag != .windows) {
        const before = std.c.fcntl(fd, std.c.F.GETFL);
        try sock_ready.sendAll(io, fd, "b", 1000);
        try std.testing.expectEqual(before, std.c.fcntl(fd, std.c.F.GETFL));
    }
}

test "native connect to a closed loopback port is refused" {
    var listener = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    const address = listener.socket.address;
    listener.deinit(io);
    try std.testing.expectError(error.ConnectionRefused, address.connect(io, .{ .mode = .stream }));
}

test "expired send deadline sends no bytes to a writable native stream" {
    const streams = try pair();
    defer for (streams) |stream| stream.close(io);
    const sender = streams[0].socket.handle;
    const peer = streams[1].socket.handle;
    try sock_ready.sendAll(io, sender, "c", 1000);
    try std.testing.expect((try sock_ready.wait(io, peer, 1000)).readable);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 1), sock_ready.takeByte(io, peer, &byte, false));
    try std.testing.expectEqual(@as(u8, 'c'), byte[0]);
    const result = sock_ready.sendAll(io, sender, "forbidden", 0);
    try streams[0].shutdown(io, .send);
    try std.testing.expect((try sock_ready.wait(io, peer, 1000)).any());
    // EOF proves the peer received no prefix, even if sendAll reports Timeout.
    try std.testing.expectEqual(@as(?usize, 0), sock_ready.takeByte(io, peer, &byte, true));
    try std.testing.expectError(error.Timeout, result);
}
