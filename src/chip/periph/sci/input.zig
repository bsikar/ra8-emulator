//! Host input polled at board boundaries and queued on the console SCI.
const ByteSource = @import("../byte_source.zig").ByteSource;
const sci = @import("sci.zig");
const sci_reply = @import("reply.zig");

pub const Hook = struct {
    context: *anyopaque,
    feedFn: *const fn (context: *anyopaque, bytes: []const u8) void,
    /// True while the host must not be heard: a replay's keystrokes come
    /// from its history. Null never holds.
    heldFn: ?*const fn (context: *anyopaque) bool = null,
};

pub const Input = struct {
    /// `--console`: the host stream typed into SCI8, filled by the
    /// application (the CLI's own stdin). Null means no console input.
    source: ?ByteSource = null,
    /// `--console-reply`: typed after its prompt, with or without stdin.
    reply: sci_reply.Reply = .{},
    /// Choke point routing for console keystrokes (RA8EMU-1196, slice 20).
    hook: ?Hook = null,

    /// Move bytes waiting on the host stream into SCI8's RX ring.
    /// The read never waits, which keeps the run loop in control of progress.
    pub fn poll(self: *Input, unit: *sci.Sci) void {
        self.pollWith(unit, sendBytes);
    }

    /// Move bytes waiting on the host stream into any receiver exposing `pushRx`.
    pub fn pollPush(self: *Input, receiver: anytype) void {
        self.pollWith(receiver, pushBytes);
    }

    fn pollWith(self: *Input, context: anytype, comptime writeFn: anytype) void {
        if (self.skipHeldReply()) return;
        if (self.takeReply()) |text| {
            writeFn(self, context, text);
            writeFn(self, context, "\n");
        }
        const source = self.source orelse return;
        var bytes: [256]u8 = undefined;
        const count = source.read(&bytes) orelse return;
        if (count == 0) {
            self.source = null;
            return;
        }
        writeFn(self, context, bytes[0..count]);
    }

    fn skipHeldReply(self: *Input) bool {
        const h = self.hook orelse return false;
        const held = h.heldFn orelse return false;
        if (!held(h.context)) return false;
        if (self.reply.due) {
            self.reply.due = false;
            self.reply.sent = true;
        }
        return true;
    }

    fn takeReply(self: *Input) ?[]const u8 {
        if (!self.reply.due) return null;
        self.reply.due = false;
        self.reply.sent = true;
        return self.reply.text;
    }

    fn sendBytes(self: *Input, unit: *sci.Sci, bytes: []const u8) void {
        if (self.hook) |h| {
            h.feedFn(h.context, bytes);
            return;
        }
        unit.feedConsole(bytes);
    }

    fn pushBytes(_: *Input, receiver: anytype, bytes: []const u8) void {
        for (bytes) |ch| {
            receiver.pushRx(ch);
        }
    }
};
