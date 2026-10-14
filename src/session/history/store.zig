//! The hot tier: the event log's recent records kept in RAM as whole
//! frames, a bounded queue whose capacity is fixed ahead.
//!
//! Frames go in at the back whole and leave from the front whole, so a
//! reader never meets a half-record. When a frame does not fit, the
//! oldest frames make room; a frame larger than the whole queue is
//! refused rather than half-kept. Forgetting is the hot tier's own
//! decision to make: the log on disk keeps everything, so what this
//! queue drops is never lost.

const std = @import("std");
const Allocator = std.mem.Allocator;
const format = @import("format.zig");

pub const Store = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    /// The held frames live contiguously in bytes[0..held].
    held: usize = 0,

    pub const Error = error{ FrameTooBig, OutOfMemory };

    pub fn init(allocator: std.mem.Allocator, cap: usize) Allocator.Error!Store {
        const bytes = try allocator.alloc(u8, cap);
        return .{ .allocator = allocator, .bytes = bytes };
    }

    pub fn deinit(self: *Store) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn capacity(self: *const Store) usize {
        return self.bytes.len;
    }

    /// How many whole frames the queue holds right now.
    pub fn count(self: *const Store) usize {
        var n: usize = 0;
        var at: usize = 0;
        while (at < self.held) : (n += 1) at += self.frameLen(at);
        return n;
    }

    /// The `index`th frame from the front, oldest first.
    pub fn frame(self: *const Store, index: usize) []const u8 {
        std.debug.assert(index < self.count());
        var at: usize = 0;
        var i: usize = 0;
        while (i < index) : (i += 1) at += self.frameLen(at);
        return self.bytes[at..][0..self.frameLen(at)];
    }

    fn frameLen(self: *const Store, at: usize) usize {
        const len = std.mem.readInt(u32, self.bytes[at..][0..4], .little);
        return format.header_len + len;
    }

    /// Appends one whole frame, evicting the oldest frames to make room.
    pub fn append(self: *Store, data: []const u8) Error!void {
        if (data.len > self.bytes.len) return Error.FrameTooBig;
        while (self.bytes.len - self.held < data.len) {
            const oldest = self.frameLen(0);
            std.mem.copyForwards(u8, self.bytes[0 .. self.held - oldest], self.bytes[oldest..self.held]);
            self.held -= oldest;
        }
        @memcpy(self.bytes[self.held..][0..data.len], data);
        self.held += data.len;
    }

    /// Keeps only the front `frames` frames. A rewind that forks drops
    /// the records the new line rewrites this way: they sit after the
    /// fork, which is to say at the back.
    pub fn keepFrames(self: *Store, frames: usize) void {
        var at: usize = 0;
        var i: usize = 0;
        while (i < frames and at < self.held) : (i += 1) at += self.frameLen(at);
        self.held = at;
    }

    pub fn clear(self: *Store) void {
        self.held = 0;
    }
};
