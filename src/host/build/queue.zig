//! Bounded live output. Disk logs are independent of a slow subscriber.
const std = @import("std");
pub const Kind = enum(u8) { stdout, stderr, diagnostic };
pub const Event = struct { sequence: u64 = 0, kind: Kind = .stdout, len: usize = 0, bytes: [4096]u8 = undefined };
pub const Queue = struct {
    mutex: std.Io.Mutex = .init,
    slots: [64]Event = @splat(.{}),
    read_at: usize = 0,
    count: usize = 0,
    sequence: u64 = 0,
    truncated: bool = false,

    pub fn push(self: *Queue, io: std.Io, kind: Kind, bytes: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.sequence += 1;
        if (self.count == self.slots.len or bytes.len > 4096) {
            self.truncated = true;
            return;
        }
        const slot = &self.slots[(self.read_at + self.count) % self.slots.len];
        slot.sequence = self.sequence;
        slot.kind = kind;
        slot.len = bytes.len;
        @memcpy(slot.bytes[0..bytes.len], bytes);
        self.count += 1;
    }

    pub fn pop(self: *Queue, io: std.Io) ?Event {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.count == 0) return null;
        const out = self.slots[self.read_at];
        self.read_at = (self.read_at + 1) % self.slots.len;
        self.count -= 1;
        return out;
    }
};
