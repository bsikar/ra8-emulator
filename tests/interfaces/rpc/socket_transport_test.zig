const std = @import("std");
const ra8 = @import("ra8");
const Connection = ra8.rpc.socket_transport.Connection;
const ready = ra8.host.sock.ready;
const io = std.testing.io;

fn pair() ![2]Connection {
    var listener = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    defer listener.deinit(io);
    const client = try Connection.tcp(io, listener.socket.address);
    errdefer client.stream.close(io);
    try std.testing.expect((try ready.wait(io, listener.socket.handle, 1000)).any());
    return .{ .{ .stream = try listener.accept(io), .io = io }, client };
}

test "socket transport polls idle, transfers bytes and preserves unread bytes before FIN" {
    var peers = try pair();
    defer for (&peers) |*peer| peer.close();
    const incoming = peers[0].transport();
    const outgoing = peers[1].transport();
    try std.testing.expectEqual(@as(usize, 0), incoming.vtable.poll(incoming.ctx));
    try outgoing.vtable.send(outgoing.ctx, "rpc");
    try peers[1].stream.shutdown(io, .send);
    try std.testing.expect((try ready.wait(io, peers[0].stream.socket.handle, 1000)).any());
    var buffer: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try incoming.vtable.receive(incoming.ctx, &buffer));
    try std.testing.expectEqualStrings("rpc", &buffer);
    try std.testing.expect((try ready.wait(io, peers[0].stream.socket.handle, 1000)).any());
    try std.testing.expectEqual(@as(usize, 0), try incoming.vtable.receive(incoming.ctx, &buffer));
}

test "RPC send drops a saturated slow link within its deadline" {
    var peers = try pair();
    defer for (&peers) |*peer| peer.close();
    const bytes = try std.testing.allocator.alloc(u8, 16 * 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'r');
    const wire = peers[0].transport();
    const start = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    var dropped = false;
    for (0..16) |_| {
        wire.vtable.send(wire.ctx, bytes) catch |err| {
            try std.testing.expectEqual(error.LinkDown, err);
            dropped = true;
            break;
        };
    }
    try std.testing.expect(dropped);
    try std.testing.expect(std.Io.Timestamp.now(io, .awake).toMilliseconds() - start < 5000);
}
