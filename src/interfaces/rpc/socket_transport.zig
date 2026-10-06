//! RPC byte transports over connected TCP and Unix domain sockets (RA8EMU-194).
const std = @import("std");
const rpc = @import("ra8_rpc");

pub const Connection = struct {
    stream: std.net.Stream,
    pub fn fromFd(fd: std.posix.fd_t) Connection {
        return .{ .stream = .{ .handle = fd } };
    }
    pub fn tcp(address: std.net.Address) !Connection {
        return .{ .stream = try std.net.tcpConnectToAddress(address) };
    }
    pub fn unix(path: []const u8) !Connection {
        return .{ .stream = try std.net.connectUnixSocket(path) };
    }
    pub fn transport(self: *Connection) rpc.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }
    pub fn close(self: *Connection) void {
        self.stream.close();
    }
    const vtable: rpc.Transport.VTable = .{ .send = send, .receive = receive, .poll = poll };
    fn from(ctx: *anyopaque) *Connection {
        return @ptrCast(@alignCast(ctx));
    }
    fn send(ctx: *anyopaque, bytes: []const u8) rpc.Transport.Error!void {
        from(ctx).stream.writeAll(bytes) catch return error.LinkDown;
    }
    fn receive(ctx: *anyopaque, into: []u8) rpc.Transport.Error!usize {
        const self = from(ctx);
        var fds = [_]std.posix.pollfd{.{ .fd = self.stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&fds, 0) catch return error.LinkDown;
        if (fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) == 0) return 0;
        return self.stream.read(into) catch return error.LinkDown;
    }
    fn poll(ctx: *anyopaque) usize {
        const self = from(ctx);
        var fds = [_]std.posix.pollfd{.{ .fd = self.stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&fds, 0) catch return 0;
        return if (fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) 1 else 0;
    }
};
