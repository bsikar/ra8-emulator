//! The transport's reverse-continue machinery: a backward search over the
//! recorded path for the latest breakpoint or fault behind the run.
//!
//! Replays forward from the checkpoint at or before the cursor with both
//! cores' armed points live, keeps the latest hit in position order, and falls
//! back to the previous checkpoint's interval when an interval holds none;
//! with no checkpoint behind, the run settles at the history's beginning
//! with history_start.

const std = @import("std");
const api = @import("../api.zig");
const command_mod = @import("command.zig");
const position_mod = @import("../history/position.zig");
const seek_engine = @import("../history/seek_engine.zig");
const transport_mod = @import("transport.zig");

const Transport = transport_mod.Transport;
const Job = transport_mod.Job;
const Error = command_mod.Error;
const Ticket = command_mod.Ticket;

/// A reverse-continue's plan: the backward search's cursor, the
/// interval being replayed, and the two passes' state.
pub const Rc = struct {
    /// The position the job queued at.
    cursor: seek_engine.Position,
    /// The interval's exclusive upper bound: the cursor for the
    /// first interval, the previous base's position after a
    /// fallback.
    upper: seek_engine.Position,
    /// Where the replay starts: the interval's base checkpoint, or
    /// `.current` when the log held nothing and the machine's own
    /// initial state is the history's beginning.
    base: seek_engine.Base,
    /// The checkpoint strictly before `base`, for the
    /// previous-interval fallback.
    prior: ?seek_engine.Base = null,
    /// Whether the base's object is already restored.
    restored: bool = false,
    /// The latest hit found in position order, strictly before the
    /// interval's upper bound.
    found: ?seek_engine.Position = null,
    /// Whether discovery is done and the landing replay drives.
    landing: bool = false,
    /// Whether the landing's base is already restored.
    landing_restored: bool = false,
    /// The job settles at the history's beginning at once: the
    /// machine never stopped, so no earlier slot exists.
    start: bool = false,
    /// The base the machine queued at, fixed once: a cancel returns
    /// the machine to this checkpoint exactly.
    origin: seek_engine.Base,

    /// Records a hit, keeping the latest one in position order: a
    /// fallback's replay passes older positions again, and an older
    /// stop must never displace a newer hit.
    pub fn note(self: *Rc, position: seek_engine.Position) void {
        const newer = if (self.found) |found| blk: {
            const order = position_mod.compare(position, found) catch break :blk true;
            break :blk order == .gt;
        } else true;
        if (newer) self.found = position;
    }
};

/// Validate, plan and queue a reverse-continue against the bound
/// history bridge.
pub fn queue(self: *Transport) !Ticket {
    const bridge = self.history orelse return Error.NotReady;
    const cpu0 = self.session.machine(.cpu0) catch return Error.HistoryBroken;
    for (cpu0.watches.entries()) |slot| if (slot.enabled) return Error.WatchArmed;
    if (self.session.hasCore(.cpu1)) {
        const cpu1 = self.session.machine(.cpu1) catch return Error.HistoryBroken;
        for (cpu1.watches.entries()) |slot| if (slot.enabled) return Error.WatchArmed;
    }
    const facts = bridge.facts(bridge.context) catch return Error.HistoryBroken;
    const core = self.session.currentCore();
    const prior = transport_mod.budgetOf(self.session, core);
    if (self.session.grid == null) {
        // The machine has never stopped: there is no earlier slot
        // to search back to, so the run settles with history_start at once.
        self.cancel();
        self.epoch += 1;
        const ticket = self.issue();
        self.job = .{
            .ticket = ticket,
            .epoch = self.epoch,
            .core = core,
            .kind = .rcont,
            .prior_budget = prior,
            .rc = .{ .cursor = .{}, .upper = .{}, .base = .current, .prior = null, .start = true, .origin = .current },
        };
        return ticket;
    }
    const grid = self.session.grid.?;
    const plan = switch (seek_engine.backBase(grid.at, facts)) {
        .plan => |plan| plan,
        .pending => return Error.NotReady,
    };
    const base = plan.base;
    const checkpoint = switch (base) {
        .checkpoint => |checkpoint| checkpoint,
        .current => return Error.NotReady,
    };
    // The checkpoint strictly before the base's, for the previous-interval fallback.
    var earlier: ?seek_engine.Base = null;
    for (facts.checkpoints) |c| {
        const before = position_mod.compare(c.position, checkpoint.position) catch continue;
        if (before != .lt) continue;
        const better = earlier == null or c.position.r > earlier.?.checkpoint.position.r;
        if (better) earlier = .{ .checkpoint = .{ .id = c.id, .object = c.object, .position = c.position } };
    }
    self.cancel();
    self.epoch += 1;
    const ticket = self.issue();
    self.job = .{
        .ticket = ticket,
        .epoch = self.epoch,
        .core = core,
        .kind = .rcont,
        .prior_budget = prior,
        .budget = prior,
        .rc = .{ .cursor = grid.at, .upper = grid.at, .base = base, .prior = earlier, .origin = base },
    };
    return ticket;
}

/// Drive one reverse-continue in two passes over the committed log.
pub fn slice(self: *Transport, job: *Job) !?api.Ended {
    defer self.session.replaying = false;
    self.session.replaying = true;
    const rc = &job.rc.?;
    if (rc.start) return .{ .stop = .history_start };
    const grid = self.session.grid orelse return error.NoGrid;
    if (rc.landing) {
        return landingSlice(self, job, rc, grid);
    }
    if (!rc.restored) {
        try self.restoreBase(rc.base);
        rc.restored = true;
        // A base that itself sits at an armed breakpoint is a hit at
        // the base's position: the replay's first resume executes
        // through it, so ask the state before running.
        const before = position_mod.compare(grid.at, rc.cursor) catch return error.OtherLine;
        if (before == .lt and rcBaseHit(self, grid.at)) rc.note(grid.at);
        return null;
    }
    const before = position_mod.compare(grid.at, rc.upper) catch return error.OtherLine;
    if (before != .lt) {
        if (rc.found != null) {
            rc.landing = true;
            rc.landing_restored = false;
            return null;
        }
        if (rc.prior) |earlier| {
            return fallback(self, rc, earlier);
        }
        try self.restoreBase(rc.base);
        return .{ .stop = .history_start };
    }
    const ended = try self.session.run(job.core, .cont);
    if (ended == .count) return null;
    const at = position_mod.compare(grid.at, rc.cursor) catch return error.OtherLine;
    if (at == .lt) rc.note(grid.at);
    return null;
}

fn landingSlice(self: *Transport, job: *Job, rc: *Rc, grid: anytype) !?api.Ended {
    if (!rc.landing_restored) {
        try self.restoreBase(rc.base);
        rc.landing_restored = true;
        return null;
    }
    const found = rc.found orelse return error.NoHit;
    const at = position_mod.compare(grid.at, found) catch return error.OtherLine;
    if (at == .gt) return error.OtherLine;
    if (at == .eq) return try rcHitStop(self, found.phase);
    const ended = try self.session.run(job.core, .cont);
    if (ended == .count) {
        const after = position_mod.compare(grid.at, found) catch return error.OtherLine;
        if (after == .lt) return null;
        return error.OtherLine;
    }
    const landed = position_mod.compare(grid.at, found) catch return error.OtherLine;
    if (landed == .lt) return null;
    return ended;
}

fn fallback(self: *Transport, rc: *Rc, earlier: seek_engine.Base) !?api.Ended {
    const upper = switch (rc.base) {
        .checkpoint => |base| base.position,
        .current => return error.NoGrid,
    };
    const bridge = self.history orelse return Error.NotReady;
    const facts = bridge.facts(bridge.context) catch return Error.HistoryBroken;
    var next: ?seek_engine.Base = null;
    for (facts.checkpoints) |c| {
        const order = position_mod.compare(c.position, earlier.checkpoint.position) catch continue;
        if (order != .lt) continue;
        const better = next == null or c.position.r > next.?.checkpoint.position.r;
        if (better) next = .{ .checkpoint = .{ .id = c.id, .object = c.object, .position = c.position } };
    }
    rc.base = earlier;
    rc.upper = upper;
    rc.prior = next;
    rc.restored = false;
    return null;
}

/// Whether the state at `position` sits at an armed breakpoint on
/// the core that retired there.
pub fn rcBaseHit(self: *Transport, position: seek_engine.Position) bool {
    const core = switch (position.phase) {
        .cpu0 => api.Core.cpu0,
        .cpu1 => api.Core.cpu1,
        .board => return false,
    };
    const machine = self.session.machine(core) catch return false;
    const pc = self.session.register(core, .pc) catch return false;
    return machine.breaks.hit(pc) != null;
}

/// The stop a landing on an armed breakpoint settles with: the hit
/// the state sits on, read off the machine.
pub fn rcHitStop(self: *Transport, phase: position_mod.Phase) !api.Ended {
    const core = switch (phase) {
        .cpu0 => api.Core.cpu0,
        .cpu1 => api.Core.cpu1,
        .board => return error.NoHit,
    };
    const machine = self.session.machine(core) catch return error.NoHit;
    const pc = self.session.register(core, .pc) catch return error.NoHit;
    const hit = machine.breaks.hit(pc) orelse return error.NoHit;
    return .{ .stop = .{ .breakpoint = hit } };
}
