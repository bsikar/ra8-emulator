const std = @import("std");
const ra8 = @import("ra8");
const ready = ra8.host.sock.ready;
const io = std.testing.io;

test "interrupt poll consumes 03 once and preserves an ordinary GDB packet" {
    var listener = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    defer listener.deinit(io);
    const client = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    try std.testing.expect((try ready.wait(io, listener.socket.handle, 1000)).any());
    const peer = try listener.accept(io);
    defer peer.close(io);
    var socket: ra8.gdb.rsp.poll.Socket = .{ .handle = peer.socket.handle, .io = io };
    const check = socket.poll();
    try std.testing.expect(!check.check(check.context));
    try ready.sendAll(io, client.socket.handle, "\x03$?#3f", 1000);
    try std.testing.expect((try ready.wait(io, peer.socket.handle, 1000)).readable);
    try std.testing.expect(check.check(check.context));
    for (0..16) |_| try std.testing.expect(!check.check(check.context));
    for ("$?#3f") |expected| {
        var byte: [1]u8 = undefined;
        try std.testing.expectEqual(@as(?usize, 1), ready.takeByte(io, peer.socket.handle, &byte, false));
        try std.testing.expectEqual(expected, byte[0]);
    }
    try std.testing.expect(!check.check(check.context));
}
