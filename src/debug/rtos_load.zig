//! CPU load from the RTOS trace's events (RA8EMU-269).
//!
//! Fed the same events src/debug/rtos_trace.zig records, in order, this
//! charges the virtual time between two of them to whatever ran in it on
//! that core: the innermost active exception if one is, else the running
//! thread, else idle. Time before a core's first event goes to `before`,
//! because nothing yet says what ran.
//!
//! Only time inside the window [from, to) is charged, and totals run as the
//! events arrive, so the load does not depend on the trace's 256-event ring
//! and costs fixed memory however long the run goes.
const std = @import("std");
const rtos_trace = @import("rtos_trace.zig");

pub const limits = struct {
    /// Distinct owners (threads, exceptions, idle) kept per core. Time for
    /// any past this goes to `Core.other`.
    pub const slots: usize = 32;
    /// Exceptions nested deeper than this keep charging the deepest kept.
    pub const depth: usize = 8;
    pub const cores: usize = rtos_trace.limits.cores;
};

pub const Kind = enum { before, idle, thread, exception };

/// What time is charged to: a thread by its control block, an exception
/// by its number, or idle or `before` with no id.
pub const Owner = struct {
    kind: Kind,
    id: u32 = 0,

    fn eql(self: Owner, other: Owner) bool {
        return self.kind == other.kind and self.id == other.id;
    }
};

pub const Slot = struct {
    owner: Owner,
    ticks: u64 = 0,
};

/// One core's running state and totals.
pub const Core = struct {
    since: u64 = 0,
    thread: Owner = .{ .kind = .before },
    stack: [limits.depth]u16 = undefined,
    depth: usize = 0,
    slots: [limits.slots]Slot = undefined,
    len: usize = 0,
    /// Ticks owed to owners past `limits.slots`.
    other: u64 = 0,

    fn running(self: *const Core) Owner {
        if (self.depth == 0) return self.thread;
        const top = @min(self.depth, limits.depth) - 1;
        return .{ .kind = .exception, .id = self.stack[top] };
    }

    fn add(self: *Core, owner: Owner, ticks: u64) void {
        if (ticks == 0) return;
        for (self.slots[0..self.len]) |*one| {
            if (one.owner.eql(owner)) {
                one.ticks += ticks;
                return;
            }
        }
        if (self.len == limits.slots) {
            self.other += ticks;
            return;
        }
        self.slots[self.len] = .{ .owner = owner, .ticks = ticks };
        self.len += 1;
    }

    fn take(self: *Core, one: rtos_trace.Event) void {
        switch (one.kind) {
            .switch_to => self.thread = .{ .kind = .thread, .id = one.thread },
            .idle => self.thread = .{ .kind = .idle },
            .enter => {
                if (self.depth < limits.depth) self.stack[self.depth] = one.exception;
                self.depth += 1;
            },
            .leave => self.depth -|= 1,
        }
    }
};

pub const Load = struct {
    from: u64 = 0,
    to: u64 = std.math.maxInt(u64),
    cores: [limits.cores]Core = .{ .{}, .{} },

    /// Take one trace event. Events for one core must come in time order.
    pub fn feed(self: *Load, one: rtos_trace.Event) void {
        self.charge(one.core, one.when);
        self.cores[one.core].take(one);
    }

    /// Charge every core up to `now`, as the run ends.
    pub fn finish(self: *Load, now: u64) void {
        for (0..limits.cores) |index| self.charge(@intCast(index), now);
    }

    /// The owners one core's time went to, in the order first charged.
    pub fn rows(self: *const Load, core: u1) []const Slot {
        const one = &self.cores[core];
        return one.slots[0..one.len];
    }

    /// Every tick charged on one core, `other` included.
    pub fn total(self: *const Load, core: u1) u64 {
        const one = &self.cores[core];
        var sum: u64 = one.other;
        for (one.slots[0..one.len]) |slot| sum += slot.ticks;
        return sum;
    }

    fn charge(self: *Load, core: u1, now: u64) void {
        const one = &self.cores[core];
        const start = @max(one.since, self.from);
        const end = @min(now, self.to);
        if (end > start) one.add(one.running(), end - start);
        if (now > one.since) one.since = now;
    }
};
