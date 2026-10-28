//! Feeds the navigation index from the run as it happens: a round boundary
//! is an iteration, and a thread switch or an exception entry or return on
//! CPU0 is stamped with the position it happened at.
//!
//! The position is read off the scheduler state: the round, CPU0's phase,
//! and the offset in architectural slots, which counts the trips a counted
//! loop skipped (the core charges them as retired slots), so a skipped
//! `k * n` is in the index's slot count without a separate record. A replay
//! passes the same boundaries again: each entry is added once, whatever
//! order the run reaches it in, so a seek back over a stretch first skipped
//! by a restore fills it in and never lists a boundary twice.
const std = @import("std");
const api = @import("../api.zig");
const line = @import("../line.zig");
const nav_index = @import("nav_index.zig");
const position_mod = @import("position.zig");
const rtos_trace = @import("../rtos/trace.zig");
const scheduler = @import("ra8_chip").core.scheduler;

pub const Position = position_mod.Position;

pub const NavFeed = struct {
    nav: *nav_index.NavIndex,
    session: *const api.Session,
    /// The run's saved scheduler state and CPU0's slot counter.
    saved: *const scheduler.State,
    slots: *const u64,
    /// CPU0's slot counter when the feed started, and the thread last
    /// seen running.
    base_slots: u64 = 0,
    thread: u32 = 0,
    /// The entries already indexed, so a replay adds nothing twice.
    seen: std.AutoHashMapUnmanaged(Seen, void) = .empty,

    /// What tells two index entries apart: the kind, its detail (the
    /// threads switched, or the exception and its direction) and where.
    const Seen = struct {
        kind: enum(u8) { iteration, switch_, isr },
        a: u32 = 0,
        b: u32 = 0,
        at: Position,
    };

    pub fn deinit(self: *NavFeed) void {
        self.seen.deinit(self.nav.allocator);
    }

    pub fn observer(self: *NavFeed) rtos_trace.Observer {
        return .{ .context = self, .eventFn = &onEvent };
    }

    /// The position CPU0 stands at right now, after the last retired slot.
    pub fn here(self: *const NavFeed) Position {
        const base = self.saved.base[0];
        const offset: u32 = @intCast(@min(self.slots.* -| base, std.math.maxInt(u32)));
        return .{
            .branch = line.currentPosition(self.session).branch,
            .r = self.saved.at.r,
            .phase = .cpu0,
            .o = offset,
            .gap = .retired,
        };
    }

    /// A round closed: the next one starts here. Its slot count is the
    /// slots run since the feed started, skipped trips included, read off
    /// CPU0's counter, which a restore puts back with the rest of the state.
    pub fn onRound(context: *anyopaque, at: Position) void {
        const self: *NavFeed = @ptrCast(@alignCast(context));
        var stamped = at;
        stamped.branch = line.currentPosition(self.session).branch;
        if (!self.first(.{ .kind = .iteration, .at = stamped })) return;
        _ = self.nav.addIterationAt(stamped, self.slots.* -| self.base_slots) catch {};
    }

    fn onEvent(context: *anyopaque, event: rtos_trace.Event) void {
        const self: *NavFeed = @ptrCast(@alignCast(context));
        if (event.core != 0) return;
        const at = self.here();
        switch (event.kind) {
            .switch_to, .idle => {
                const to: u32 = if (event.kind == .idle) 0 else event.thread;
                const from = self.thread;
                self.thread = to;
                if (!self.first(.{ .kind = .switch_, .a = from, .b = to, .at = at })) return;
                self.nav.addRtosSwitch(from, to, at, 0) catch {};
            },
            .enter, .leave => {
                const entry = @intFromBool(event.kind == .enter);
                if (!self.first(.{ .kind = .isr, .a = event.exception, .b = entry, .at = at })) return;
                self.nav.addIsr(event.exception, event.kind == .enter, at, 0) catch {};
            },
        }
    }

    /// Whether `entry` is new to the index; it is remembered either way.
    /// Out of memory, it is skipped, so the index only misses an entry.
    fn first(self: *NavFeed, entry: Seen) bool {
        const got = self.seen.getOrPut(self.nav.allocator, entry) catch return false;
        return !got.found_existing;
    }
};
