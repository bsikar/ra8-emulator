//! Host stdin polled at board boundaries and queued on the console SCI.
const std = @import("std");
const sci = @import("sci.zig");
const sci_reply = @import("sci_reply.zig");

pub const Input = struct {
    enabled: bool = false,
    fd: std.posix.fd_t = 0,
    /// `--console-reply`: typed after its prompt, with or without stdin.
    reply: sci_reply.Reply = .{},

    /// Move bytes waiting on the host input descriptor into SCI8's RX ring.
    /// A zero timeout keeps the emulator run loop in control of progress.
    pub fn poll(self: *Input, unit: *sci.Sci) void {
        self.reply.poll(unit);
        if (!self.enabled) return;
        var descriptors = [_]std.posix.pollfd{
            .{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ready = std.posix.poll(&descriptors, 0) catch return;
        if (ready == 0 or descriptors[0].revents & std.posix.POLL.IN == 0) return;

        var bytes: [256]u8 = undefined;
        const count = std.posix.read(self.fd, &bytes) catch return;
        if (count == 0) {
            self.enabled = false;
            return;
        }
        unit.feed(sci.console_channel, bytes[0..count]);
    }
};
