//! The RPC byte transport over stdin/stdout (RA8EMU-194).
const std = @import("std");
const rpc = @import("ra8_rpc");

pub const Stdio = struct {
    input: std.posix.fd_t = 0,
    output: std.posix.fd_t = 1,
    pub fn transport(self: *Stdio) rpc.Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable: rpc.Transport.VTable = .{ .send = send, .receive = receive, .poll = poll };
    fn from(ctx: *anyopaque) *Stdio {
        return @ptrCast(@alignCast(ctx));
    }
    fn send(ctx: *anyopaque, bytes: []const u8) rpc.Transport.Error!void {
        const self = from(ctx);
        var at: usize = 0;
        while (at < bytes.len) {
            const rest = bytes[at..];
            const rc = std.posix.system.write(self.output, rest.ptr, rest.len);
            switch (std.posix.errno(rc)) {
                .SUCCESS => at += @intCast(rc),
                .INTR, .AGAIN => {},
                else => return error.LinkDown,
            }
        }
    }
    fn receive(ctx: *anyopaque, into: []u8) rpc.Transport.Error!usize {
        const self = from(ctx);
        var fds = [_]std.posix.pollfd{.{ .fd = self.input, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&fds, 0) catch return error.LinkDown;
        if (fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) == 0) return 0;
        const rc = std.posix.system.read(self.input, into.ptr, into.len);
        return switch (std.posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .INTR, .AGAIN => 0,
            else => error.LinkDown,
        };
    }
    fn poll(ctx: *anyopaque) usize {
        const self = from(ctx);
        var fds = [_]std.posix.pollfd{.{ .fd = self.input, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&fds, 0) catch return 0;
        return if (fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) 1 else 0;
    }
};
