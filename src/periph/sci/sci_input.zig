//! Host stdin polled at board boundaries and queued on the console SCI.
const sci = @import("sci.zig");
const sci_reply = @import("sci_reply.zig");
const host_read = @import("../host_read.zig");

pub const Input = struct {
    enabled: bool = false,
    /// The handle read; null means the process's own stdin.
    fd: ?host_read.Handle = null,
    /// `--console-reply`: typed after its prompt, with or without stdin.
    reply: sci_reply.Reply = .{},

    /// Move bytes waiting on the host input handle into SCI8's RX ring.
    /// The read never waits, which keeps the run loop in control of progress.
    pub fn poll(self: *Input, unit: *sci.Sci) void {
        self.reply.poll(unit);
        if (!self.enabled) return;
        var bytes: [256]u8 = undefined;
        const count = host_read.read(self.fd orelse host_read.stdin(), &bytes) orelse return;
        if (count == 0) {
            self.enabled = false;
            return;
        }
        unit.feed(sci.console_channel, bytes[0..count]);
    }
};
