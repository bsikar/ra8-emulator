//! The debugger's rewind history (RA8EMU-1170): a circular buffer of whole
//! state captures, one per recorded stop, that puts the run back exactly as
//! it was when the stop happened.
//!
//! Each frame serializes the same file a `--save-state` run writes (the
//! store, the core, the board, the two SysTick bases and the stretch
//! section, src/session/board/state.zig), so a restore covers periph state
//! and not just the core's registers: a rewind across a run that touched
//! hardware lands the hardware back too. The harness holds the pointers a
//! frame reads and writes (harness.zig); the ring owns the frames, its
//! capacity is the caller's stated size, and the byte total is on hand for
//! whoever displays it.
const std = @import("std");
const session_state = @import("board/state.zig");

pub const History = struct {
    files: *session_state.Files,
    gpa: std.mem.Allocator,
    /// The stated size: frames the ring keeps before it drops the oldest.
    capacity: u32,
    /// A frame's first allocation; capture grows past it when a run needs it.
    growth: usize = 1 << 16,
    ring: std.ArrayList(Frame) = .empty,
    /// Index of the oldest live frame; the newest is one behind head + count.
    head: usize = 0,
    count: u32 = 0,

    /// One recorded stop: the serialized run plus what the caller read off
    /// it. `tag` is the stop's own kind (stop, count, fault), for a rewind
    /// that looks for breakpoints in the window.
    pub const Frame = struct {
        bytes: []u8 = &.{},
        pc: u32 = 0,
        tag: u16 = 0,
        at_ns: u64 = 0,
    };

    pub const Error = error{ NotRecorded, SecondCoreNotSaved };

    pub fn init(gpa: std.mem.Allocator, files: *session_state.Files, capacity: u32) !History {
        var ring: std.ArrayList(Frame) = try .initCapacity(gpa, capacity);
        ring.items.len = capacity;
        @memset(ring.items, .{});
        return .{ .files = files, .gpa = gpa, .capacity = capacity, .ring = ring };
    }

    pub fn deinit(self: *History) void {
        for (self.ring.items) |entry| {
            if (entry.bytes.len > 0) self.gpa.free(entry.bytes);
        }
        self.ring.deinit(self.gpa);
    }

    /// Serializes the whole run into the ring; the oldest frame falls off
    /// when the ring is full. `pc`, `tag` and `at_ns` describe the stop the
    /// frame records; the caller reads them off the run that just stopped.
    pub fn capture(self: *History, pc: u32, tag: u16, at_ns: u64) anyerror!void {
        // A second core's state is not in the file yet (RA8EMU-768): a
        // dual-core run records no frames, and its rewinds say so.
        if (self.files.edge.second != null) return;
        var allocating: std.Io.Writer.Allocating = try .initCapacity(self.gpa, self.growth);
        defer allocating.deinit();
        try self.files.writeTo(&allocating.writer);
        const bytes = try self.gpa.dupe(u8, allocating.written());
        errdefer self.gpa.free(bytes);
        if (self.count < self.capacity) {
            self.ring.items[(self.head + self.count) % self.capacity] =
                .{ .bytes = bytes, .pc = pc, .tag = tag, .at_ns = at_ns };
            self.count += 1;
        } else {
            self.gpa.free(self.ring.items[self.head].bytes);
            self.ring.items[self.head] =
                .{ .bytes = bytes, .pc = pc, .tag = tag, .at_ns = at_ns };
            self.head = (self.head + 1) % self.capacity;
        }
    }

    /// Puts the run back `back` stops behind the newest; back 0 is the
    /// newest frame itself. A slot the ring has not reached refuses.
    pub fn restore(self: *History, back: u32) anyerror!void {
        try self.files.readFrom((try self.frame(back)).bytes);
    }

    /// The frame `back` stops behind the newest, for callers showing the
    /// window's contents (a rewind-to-breakpoint looks for its tag here).
    pub fn frame(self: *const History, back: u32) Error!Frame {
        if (back >= self.count) return Error.NotRecorded;
        return self.ring.items[(self.head + self.count - 1 - @as(usize, back)) % self.capacity];
    }

    /// The bytes the live frames hold, for whoever sizes or displays the ring.
    pub fn totalBytes(self: *const History) usize {
        var total: usize = 0;
        for (self.ring.items) |entry| total += entry.bytes.len;
        return total;
    }
};
