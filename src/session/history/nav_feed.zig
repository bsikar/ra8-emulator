//! Feeds the navigation index from the run as it happens: a round boundary
//! is an iteration, and a thread switch or an exception entry or return on
//! CPU0 is stamped with the position it happened at.
//!
//! The position is read off the scheduler state: the round, CPU0's phase,
//! and the offset in architectural slots, which counts the trips a counted
//! loop skipped (the core charges them as retired slots), so a skipped
//! `k * n` is in the index's slot count without a separate record. A replay
//! passes the same boundaries again; an entry is added only past the newest
//! one already indexed, so a seek never lists a boundary twice.
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
    /// Slots already charged to the index, and the thread last seen running.
    charged: u64 = 0,
    thread: u32 = 0,
    /// The newest position of each kind indexed, so a replay adds nothing.
    last_iteration: ?Position = null,
    last_switch: ?Position = null,
    last_isr: ?Position = null,

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

    /// A round closed: the next one starts here. The slots run since the
    /// last boundary, skipped trips included, join the iteration's count.
    pub fn onRound(context: *anyopaque, at: Position) void {
        const self: *NavFeed = @ptrCast(@alignCast(context));
        var stamped = at;
        stamped.branch = line.currentPosition(self.session).branch;
        if (!newer(self.last_iteration, stamped)) return;
        self.last_iteration = stamped;
        self.nav.advanceSlots(self.slots.* -| self.charged);
        self.charged = self.slots.*;
        _ = self.nav.addIteration(stamped) catch {};
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
                if (!newer(self.last_switch, at)) return;
                self.last_switch = at;
                self.nav.addRtosSwitch(from, to, at, 0) catch {};
            },
            .enter, .leave => {
                if (!newer(self.last_isr, at)) return;
                self.last_isr = at;
                self.nav.addIsr(event.exception, event.kind == .enter, at, 0) catch {};
            },
        }
    }

    fn newer(last: ?Position, at: Position) bool {
        const held = last orelse return true;
        return (position_mod.compare(held, at) catch .lt) == .lt;
    }
};
