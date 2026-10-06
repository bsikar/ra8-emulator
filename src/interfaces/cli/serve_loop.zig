//! The answer loop the serve front runs on one connected peer (RA8EMU-736).
const std = @import("std");
const served = @import("../rpc/session_server.zig");
const Stdio = @import("../rpc/stdio_transport.zig").Stdio;
const socket_flags = @import("../socket_flags.zig");

/// How long an idle server waits on its peer before checking again.
const idle_wait_ms = 20;

pub const Buffers = struct { rx: []u8, tx: []u8 };

/// What the peer's descriptor is, which decides how a hang-up shows.
pub const Link = enum { pipe, socket };

/// Set from a signal handler; the loops end at their next idle check.
pub var stopping = std.atomic.Value(bool).init(false);

/// Answer the client on stdin and stdout until stdin closes.
pub fn answerStdio(context: *served.Context, buffers: Buffers) !void {
    var stdio: Stdio = .{};
    try answer(context, stdio.transport(), stdio.input, .pipe, buffers);
}

/// Answer frames on `wire` until the peer behind `fd` closes or a stop is asked.
pub fn answer(context: *served.Context, wire: served.rpc_lib.Transport, fd: std.posix.fd_t, link: Link, buffers: Buffers) !void {
    var host = served.Host.init(wire, buffers.rx, context);
    while (true) {
        if (try host.poll(buffers.tx) != .idle) continue;
        if (stopping.load(.acquire) or try closed(fd, link)) return;
    }
}

/// Wait briefly on `fd`; true once the peer hung up with nothing left to read.
/// A pipe reports that as HUP. A socket reports it as readable with zero
/// bytes behind it, so the socket is peeked.
fn closed(fd: std.posix.fd_t, link: Link) !bool {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    _ = try std.posix.poll(&fds, idle_wait_ms);
    const revents = fds[0].revents;
    if (revents & std.posix.POLL.IN == 0) return revents & std.posix.POLL.HUP != 0;
    if (link == .pipe) return false;
    var byte: [1]u8 = undefined;
    const flags = socket_flags.peek | socket_flags.dontwait;
    const got = std.posix.recvfrom(fd, &byte, flags, null, null) catch |err| return err != error.WouldBlock;
    return got == 0;
}
