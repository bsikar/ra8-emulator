//! The peripheral accesses Unicorn made on one lockstep step, replayed into
//! the Zig core so no peripheral sees an access twice.
//!
//! In lockstep the oracle owns every peripheral side effect: Unicorn steps
//! first and reaches the board's peripherals through its MMIO hooks as it
//! always does, and a tap writes down each read with the value it returned
//! and each write with the value it stored. The Zig core then runs the same
//! instruction against this log instead of the peripherals. Its reads are
//! answered from the log in order, and its writes are checked against the
//! log, so a peripheral access is compared rather than repeated.
const std = @import("std");

/// More than one instruction makes: LDM or STM of every register is 16.
pub const capacity = 32;

pub const Kind = enum { read, write };

pub const Access = struct {
    address: u32,
    width: u3,
    value: u32,
};

/// The first way the Zig core's peripheral accesses differed from Unicorn's.
pub const Mismatch = struct {
    kind: Kind,
    /// What the Zig core did; null when Unicorn made an access it did not.
    ours: ?Access,
    /// What Unicorn did at that point; null when it made no such access.
    oracle: ?Access,

    pub fn write(self: Mismatch, out: anytype) !void {
        try out.print("peripheral {s}: zig ", .{@tagName(self.kind)});
        try writeAccess(out, self.ours);
        try out.writeAll(", unicorn ");
        try writeAccess(out, self.oracle);
    }

    fn writeAccess(out: anytype, access: ?Access) !void {
        const a = access orelse return out.writeAll("none");
        try out.print("{d} byte(s) at 0x{X:0>8} = 0x{X}", .{ a.width, a.address, a.value });
    }
};

const Queue = struct {
    held: [capacity]Access = undefined,
    count: usize = 0,
    next: usize = 0,

    fn push(self: *Queue, access: Access) bool {
        if (self.count == capacity) return false;
        self.held[self.count] = access;
        self.count += 1;
        return true;
    }

    fn peek(self: *const Queue) ?Access {
        return if (self.next < self.count) self.held[self.next] else null;
    }
};

pub const Log = struct {
    reads: Queue = .{},
    writes: Queue = .{},
    /// Set while an instruction Unicorn also ran is being replayed. A Zig
    /// core peripheral access outside that has nothing to answer it.
    armed: bool = false,
    /// More accesses than `capacity` in one step; the step cannot be checked.
    overflow: bool = false,
    mismatch: ?Mismatch = null,
    /// Peripheral accesses matched over the whole run.
    matched: u64 = 0,

    /// Start a step: forget the last one's accesses, keep the run's count.
    pub fn begin(self: *Log, armed: bool) void {
        self.* = .{ .armed = armed, .matched = self.matched };
    }

    pub fn noteRead(self: *Log, access: Access) void {
        if (!self.reads.push(access)) self.overflow = true;
    }

    pub fn noteWrite(self: *Log, access: Access) void {
        if (!self.writes.push(access)) self.overflow = true;
    }

    /// The value Unicorn read for the Zig core's next read, or null with the
    /// mismatch recorded when the two reads are not the same access.
    pub fn takeRead(self: *Log, address: u32, width: u3) ?u32 {
        const theirs = self.reads.peek();
        if (theirs) |t| if (t.address == address and t.width == width) {
            self.reads.next += 1;
            self.matched += 1;
            return t.value;
        };
        self.fail(.read, .{ .address = address, .width = width, .value = 0 }, theirs);
        return null;
    }

    /// Check the Zig core's next write against Unicorn's.
    pub fn takeWrite(self: *Log, access: Access) void {
        const theirs = self.writes.peek();
        if (theirs) |t| if (std.meta.eql(t, access)) {
            self.writes.next += 1;
            self.matched += 1;
            return;
        };
        self.fail(.write, access, theirs);
    }

    /// After the Zig core's step: the first difference, including an access
    /// Unicorn made that the Zig core never did.
    pub fn verdict(self: *const Log) ?Mismatch {
        if (self.mismatch) |found| return found;
        if (self.reads.peek()) |left| return .{ .kind = .read, .ours = null, .oracle = left };
        if (self.writes.peek()) |left| return .{ .kind = .write, .ours = null, .oracle = left };
        return null;
    }

    fn fail(self: *Log, kind: Kind, ours: Access, theirs: ?Access) void {
        if (self.mismatch == null) self.mismatch = .{ .kind = kind, .ours = ours, .oracle = theirs };
    }
};
