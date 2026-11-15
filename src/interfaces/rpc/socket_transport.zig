//! RPC byte transports over connected TCP and Unix domain sockets (RA8EMU-194).

const builtin = @import("builtin");
const rpc = @import("ra8_rpc_wire");
const sock_ready = @import("ra8_host").sock.ready;
const sock_unix = @import("ra8_host").sock.unix;
const std = @import("std");

pub const Connection = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    unix_socket: bool = false,
    pub fn fromFd(io: std.Io, fd: std.posix.fd_t) Connection {
        return .{ .stream = .{ .socket = .{ .handle = fd, .address = .{ .ip4 = .loopback(0) } } }, .io = io };
    }
    pub fn tcp(io: std.Io, address: std.Io.net.IpAddress) !Connection {
        return .{ .stream = try address.connect(io, .{ .mode = .stream }), .io = io };
    }
    pub fn unix(io: std.Io, path: []const u8) !Connection {
        return .{ .stream = try sock_unix.connect(io, path), .io = io, .unix_socket = builtin.os.tag == .windows };
    }
    pub fn transport(self: *Connection) rpc.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }
    pub fn close(self: *Connection) void {
        if (self.unix_socket) sock_unix.close(self.io, self.stream.socket.handle) else self.stream.close(self.io);
    }
    const vtable: rpc.Transport.VTable = .{ .send = send, .receive = receive, .poll = poll };
    fn from(ctx: *anyopaque) *Connection {
        return @ptrCast(@alignCast(ctx));
    }
    fn waitReady(self: *Connection) !sock_ready.Ready {
        return if (self.unix_socket)
            sock_unix.wait(self.io, self.stream.socket.handle, 0)
        else
            sock_ready.wait(self.io, self.stream.socket.handle, 0);
    }
    fn send(ctx: *anyopaque, bytes: []const u8) rpc.Transport.Error!void {
        const self = from(ctx);
        const sent = if (self.unix_socket)
            sock_unix.sendAll(self.io, self.stream.socket.handle, bytes, 100)
        else
            sock_ready.sendAll(self.io, self.stream.socket.handle, bytes, 100);
        sent catch return error.LinkDown;
    }
    fn receive(ctx: *anyopaque, into: []u8) rpc.Transport.Error!usize {
        const self = from(ctx);
        const ready = self.waitReady() catch return error.LinkDown;
        if (!ready.any()) return 0;
        if (self.unix_socket) return sock_unix.read(self.io, self.stream.socket.handle, into);
        var vec = [_][]u8{into};
        const got = self.stream.readWithControl(self.io, &vec, &.{}) catch return error.LinkDown;
        return got.data_len;
    }
    fn poll(ctx: *anyopaque) usize {
        const self = from(ctx);
        const ready = self.waitReady() catch return 0;
        return @intFromBool(ready.any());
    }
};
