//! Whether gdb sent an interrupt (0x03) while a resume runs.
//!
//! The session asks between run chunks (src/debug/session.zig, `Poll`).
//! The check peeks at the connection without waiting. An interrupt byte is
//! taken; anything else is left for the packet reader once the run stops.
const std = @import("std");
const packet = @import("rsp_packet.zig");
const debug_session = @import("session.zig");
const socket_flags = @import("../interfaces/socket_flags.zig");

/// Instructions per run chunk under gdb: small enough that an interrupt
/// lands promptly, large enough that polling costs nothing measurable.
pub const chunk: usize = 200_000;

pub const Socket = struct {
    handle: std.posix.socket_t,

    pub fn poll(self: *Socket) debug_session.Poll {
        return .{ .context = self, .check = check };
    }

    fn check(context: *anyopaque) bool {
        const self: *Socket = @ptrCast(@alignCast(context));
        var fds = [_]std.posix.pollfd{.{ .fd = self.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, 0) catch return false;
        if (ready == 0) return false;
        var byte: [1]u8 = undefined;
        const peeked = take(self.handle, &byte, socket_flags.peek) orelse return false;
        if (peeked == 0 or byte[0] != packet.interrupt) return false;
        _ = take(self.handle, &byte, 0) orelse return false;
        return true;
    }
};

/// One byte off the socket through libc's recv (Zig 0.17 has no
/// std.posix.recv); null when it fails.
fn take(handle: std.posix.socket_t, byte: *[1]u8, flags: u32) ?usize {
    const got = std.c.recv(handle, byte, byte.len, @intCast(flags));
    if (got < 0) return null;
    return @intCast(got);
}
