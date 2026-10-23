//! The transport's backward step machinery: discovering the prior canonical
//! stop on the stepping core's retire path, and landing on it.
//!
//! Replays forward from a checkpoint base one instruction at a time: each rest
//! is a canonical stop on that core's retire path, and the last one strictly
//! before the job's cursor is the stop the reverse step lands on.

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

/// A backward step's plan: the cursor it backs off from, the
/// checkpoint base its replay starts from, and the two passes'
/// state: discover the stop before the cursor, then land on it.
pub const Back = struct {
    /// The position the job queued at.
    cursor: seek_engine.Position,
    /// Where the replay starts: the base checkpoint, or `.current`
    /// when the log held nothing and the machine's own initial
    /// state is the history's beginning.
    base: seek_engine.Base,
    /// Whether the base's object is already restored.
    restored: bool = false,
    /// The landing position: discovered in the first pass.
    target: ?seek_engine.Position = null,
    /// The first pass's newest rest position strictly before the
    /// cursor.
    seen: ?seek_engine.Position = null,
    /// Whether the landing is the log's beginning, settled as
    /// history_start instead of a finished step.
    start: bool = false,
    /// The base the machine queued at, fixed once: a cancel returns
    /// the machine to this checkpoint exactly, whatever the replay
    /// later rebased to.
    origin: seek_engine.Base,
};

/// Validate, plan and queue a backward step against the bound history bridge.
pub fn queue(self: *Transport, step: command_mod.Step) !Ticket {
    if (step.count == 0) return Error.InvalidArgs;
    const bridge = self.history orelse return Error.NotReady;
    const facts = bridge.facts(bridge.context) catch return Error.HistoryBroken;
    const prior = transport_mod.budgetOf(self.session, step.core);
    if (self.session.grid == null) {
        return queueAtStart(self, step, facts, prior);
    }
    return queueAtGrid(self, step, facts, prior);
}

fn queueAtStart(self: *Transport, step: command_mod.Step, facts: seek_engine.Facts, prior: u64) !Ticket {
    // The machine has never stopped: the cursor sits at or before every
    // recorded checkpoint, so the step can only settle at the log's beginning.
    const planned = switch (seek_engine.backBaseAtStart(facts)) {
        .plan => |plan| plan,
        .pending => null,
    };
    self.cancel();
    self.epoch += 1;
    // The replay recreates the recorded path one instruction at a time; wakes ride along.
    try self.session.setRunBudget(step.core, 1);
    const ticket = self.issue();
    if (planned) |plan| {
        const at = plan.base.checkpoint.position;
        self.job = .{
            .ticket = ticket,
            .epoch = self.epoch,
            .core = step.core,
            .kind = .step,
            .prior_budget = prior,
            .budget = 1,
            .left = step.count,
            .dir = .back,
            .back = .{ .cursor = at, .base = plan.base, .target = at, .start = true, .origin = plan.base },
        };
    } else {
        // The log holds no checkpoint: the machine's initial state is the history's beginning.
        self.job = .{
            .ticket = ticket,
            .epoch = self.epoch,
            .core = step.core,
            .kind = .step,
            .prior_budget = prior,
            .budget = 1,
            .left = step.count,
            .dir = .back,
            .back = .{ .cursor = .{}, .base = .current, .target = null, .start = true, .origin = .current },
        };
    }
    return ticket;
}

fn queueAtGrid(self: *Transport, step: command_mod.Step, facts: seek_engine.Facts, prior: u64) !Ticket {
    const grid = self.session.grid.?;
    const plan = switch (seek_engine.backBase(grid.at, facts)) {
        .plan => |plan| plan,
        .pending => return Error.NotReady,
    };
    self.cancel();
    self.epoch += 1;
    // The replay recreates the recorded path one instruction at a time; wakes ride along.
    try self.session.setRunBudget(step.core, 1);
    const ticket = self.issue();
    self.job = .{
        .ticket = ticket,
        .epoch = self.epoch,
        .core = step.core,
        .kind = .step,
        .prior_budget = prior,
        .budget = 1,
        .left = step.count,
        .dir = .back,
        .back = .{ .cursor = grid.at, .base = plan.base, .origin = plan.base },
    };
    return ticket;
}

/// Drive one backward step in two passes over the committed log.
/// Discovery restores the base checkpoint once and replays forward
/// one instruction at a time on the stepping core: each rest is a
/// canonical stop on that core's retire path, and the last one
/// strictly before the job's cursor is the stop the reverse step
/// lands on. Nothing before the cursor is the log's beginning, so
/// the machine goes back on the base and the job settles with
/// history_start. Landing restores the base again and replays to
/// the discovered stop, the way a seek lands, then counts the step
/// and either ends or backs off one more. Correct restore+replay
/// comes before window optimizations (unit 18).
pub fn slice(self: *Transport, job: *Job) !?api.Ended {
    // The whole job replays recorded history: nothing it does is a
    // new stop, so the history ring records none of it.
    defer self.session.replaying = false;
    self.session.replaying = true;
    const back = &job.back.?;
    // A machine that never stopped with no checkpoint in the log
    // stands at the history's beginning already: nothing to
    // restore, no earlier slot, so the step settles at once.
    if (back.target == null and back.start) return .{ .stop = .history_start };
    if (!back.restored) {
        try self.restoreBase(back.base);
        back.restored = true;
        return null;
    }
    const grid = self.session.grid orelse return error.NoGrid;
    if (back.target == null) {
        return discoverPass(self, job, back, grid);
    }
    return landPass(self, job, back, grid);
}

fn discoverPass(self: *Transport, job: *Job, back: *Back, grid: anytype) !?api.Ended {
    const before = position_mod.compare(grid.at, back.cursor) catch return error.OtherLine;
    if (before == .gt) {
        const target = back.seen orelse {
            // The log's beginning: no earlier canonical stop on
            // this core's retire path. The base is the earliest
            // provable state, so rest there and say so.
            try self.restoreBase(back.base);
            return .{ .stop = .history_start };
        };
        back.target = target;
        back.restored = false;
        return null;
    }
    if (before == .lt and grid.at.phase == corePhase(job.core)) back.seen = grid.at;
    const ended = try self.session.run(job.core, .cont);
    const after = position_mod.compare(grid.at, back.cursor) catch return error.OtherLine;
    if (after == .lt and grid.at.phase == corePhase(job.core)) back.seen = grid.at;
    // A one-instruction slice that used its budget made
    // progress; anything else is a stop the replay met on the
    // way, which settles the job with it, the way a seek's
    // replay does.
    if (ended == .count) return null;
    return ended;
}

fn landPass(self: *Transport, job: *Job, back: *Back, grid: anytype) !?api.Ended {
    const ord = position_mod.compare(grid.at, back.target.?) catch return error.OtherLine;
    if (ord == .eq) {
        job.left -= 1;
        if (back.start) return .{ .stop = .history_start };
        if (job.left == 0) return .{ .stop = .stepped };
        // Another step back: the stop just landed on is the next
        // cursor, and the same base still reaches it.
        back.cursor = back.target.?;
        back.target = null;
        back.seen = null;
        back.start = false;
        back.restored = false;
        return null;
    }
    if (ord == .gt) return error.OtherLine;
    const ended = try self.session.run(job.core, .cont);
    if (ended == .count) return null;
    return ended;
}

/// The position phase a core retires on.
pub fn corePhase(core: api.Core) position_mod.Phase {
    return switch (core) {
        .cpu0 => .cpu0,
        .cpu1 => .cpu1,
    };
}
