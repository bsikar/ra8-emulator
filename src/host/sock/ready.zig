//! Whether a socket has bytes waiting or its peer hung up (RA8EMU-828).
//! POSIX uses poll; Windows uses native AFD operations on std.Io.net handles.
const std = @import("std");
const builtin = @import("builtin");
const afd = @import("afd.zig");
const socket_flags = @import("../socket_flags.zig");

pub const Handle = std.posix.fd_t;

pub const Ready = struct {
    readable: bool = false,
    hung_up: bool = false,

    /// True when a read will not block.
    pub fn any(self: Ready) bool {
        return self.readable or self.hung_up;
    }
};

/// Wait up to `ms` (0 checks without waiting) for `handle` to turn ready.
pub fn wait(io: std.Io, handle: Handle, ms: i32) error{SystemResources}!Ready {
    if (builtin.os.tag == .windows) {
        const got = afd.wait(io, handle, ms) catch return error.SystemResources;
        return .{ .readable = got.readable, .hung_up = got.hung_up };
    }
    const posix = std.posix;
    var fds = [_]posix.pollfd{.{ .fd = handle, .events = posix.POLL.IN, .revents = 0 }};
    _ = posix.poll(&fds, ms) catch return error.SystemResources;
    const got = fds[0].revents;
    return .{ .readable = got & posix.POLL.IN != 0, .hung_up = got & posix.POLL.HUP != 0 };
}

/// Reads (or with `peek`, looks at) one byte without consuming more; null
/// when the receive fails, 0 when the peer hung up (RA8EMU-943).
pub fn takeByte(io: std.Io, handle: Handle, byte: *[1]u8, peek: bool) ?usize {
    if (builtin.os.tag == .windows) {
        return afd.receive(io, handle, byte, peek, .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }) catch null;
    }
    const got = std.c.recv(handle, byte, byte.len, @as(c_int, if (peek) @intCast(std.posix.MSG.PEEK) else 0) | @as(c_int, @intCast(std.posix.MSG.DONTWAIT)));
    if (got < 0) return null;
    return @intCast(got);
}

/// Sends a whole reply within one deadline, including all partial writes.
/// A timeout drops the connection: a prefix may already have been sent.
pub fn sendAll(io: std.Io, handle: Handle, bytes: []const u8, ms: u32) !void {
    const timeout = (std.Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } }).toDeadline(io);
    var at: usize = 0;
    while (at < bytes.len) {
        if (timeout.toDurationFromNow(io).?.raw.toMilliseconds() <= 0) return error.Timeout;
        const got = if (builtin.os.tag == .windows)
            try afd.send(io, handle, bytes[at..], timeout)
        else
            try sendPosix(io, handle, bytes[at..], timeout);
        if (got == 0) return error.BrokenPipe;
        at += got;
    }
}

/// Darwin's send ignores MSG_DONTWAIT (RA8EMU-727), so the socket itself is
/// nonblocking for the call and goes back to its own flags after.
fn sendPosix(io: std.Io, handle: Handle, bytes: []const u8, timeout: std.Io.Timeout) !usize {
    const was = std.c.fcntl(handle, std.c.F.GETFL);
    if (was < 0) return error.Unexpected;
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    if (was & nonblock == 0 and std.c.fcntl(handle, std.c.F.SETFL, was | nonblock) < 0) return error.Unexpected;
    defer if (was & nonblock == 0) {
        _ = std.c.fcntl(handle, std.c.F.SETFL, was);
    };
    while (true) {
        const remaining = timeout.toDurationFromNow(io).?.raw.toMilliseconds();
        if (remaining <= 0) return error.Timeout;
        var fds = [_]std.posix.pollfd{.{ .fd = handle, .events = std.posix.POLL.OUT, .revents = 0 }};
        if (try std.posix.poll(&fds, @intCast(@min(remaining, std.math.maxInt(i32)))) == 0) return error.Timeout;
        const got = std.c.send(handle, bytes.ptr, bytes.len, @intCast(socket_flags.nosignal | std.posix.MSG.DONTWAIT));
        if (got >= 0) return @intCast(got);
        if (std.c.errno(got) != .AGAIN) return error.BrokenPipe;
    }
}
