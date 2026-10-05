//! Keys typed into the console pane (RA8EMU-206), handed from the window
//! to the engine the way source_swap.zig hands a camera pick: the window
//! posts each byte with the channel the pane showed when it was typed, and
//! the engine feeds them into that channel's RX at its next park, so the
//! SCI is only ever written on the engine's thread. Past `capacity` bytes
//! waiting, the newest are dropped and counted.
const std = @import("std");

/// Bytes that can wait between two parks.
pub const capacity: usize = 256;

/// The byte a control key types: Enter (as CR), Backspace, Tab, Escape
/// and Delete. Printable characters arrive as text events instead (so
/// Shift works), and every other key types nothing.
pub fn byteOf(code: u32) ?u8 {
    return switch (code) {
        0x08, 0x09, 0x1B, 0x7F => @intCast(code),
        0x0D => '\r',
        else => null,
    };
}

pub const Key = struct { channel: u8, byte: u8 };

pub const Typed = struct {
    mutex: std.Thread.Mutex = .{},
    pending: [capacity]Key = undefined,
    len: usize = 0,
    lost: u64 = 0,

    /// Window side: queue `byte` for `channel`.
    pub fn post(self: *Typed, channel: u8, byte: u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len == capacity) {
            self.lost += 1;
            return;
        }
        self.pending[self.len] = .{ .channel = channel, .byte = byte };
        self.len += 1;
    }

    /// Engine side: feed every waiting byte, oldest first, through
    /// `sink.feed(channel, bytes)` (sci.Sci has that shape). Returns how
    /// many were fed.
    pub fn take(self: *Typed, sink: anytype) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const count = self.len;
        for (self.pending[0..count]) |key| sink.feed(key.channel, &.{key.byte});
        self.len = 0;
        return count;
    }
};
