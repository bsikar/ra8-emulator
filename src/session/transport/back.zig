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
const back_window = @import("back_window.zig");
const run_slice = @import("../run_slice.zig");

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
    /// Whether a window build was tried for this job (back_window.zig).
    windowed: bool = false,
    /// Whether a sliced window rebuild is currently in progress.
    rebuilding: bool = false,
    /// The base the machine queued at, fixed once: a cancel returns
    /// the machine to this checkpoint or window origin exactly.
    origin: seek_engine.Base,
    /// Fallback checkpoint `<= origin` when `origin` was `.window` and a
    /// later fallback dropped that window.
    origin_checkpoint: ?seek_engine.Base = null,
};

/// Validate, plan and queue a backward step against the bound history bridge.
pub fn queue(self: *Transport, step: command_mod.Step) !Ticket {
    if (step.count == 0) return Error.InvalidArgs;
    const bridge = self.history orelse return Error.NotReady;
    var facts = bridge.facts(bridge.context) catch return Error.HistoryBroken;
    if (self.session.fork_router) |router| {
        facts.graph = router.graph;
        facts.active_line = router.active_line;
    }
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
    const origin_cp = if (plan.base == .window) checkpointAtOrBefore(self.session, grid.at, facts.checkpoints) else null;
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
        .back = .{ .cursor = grid.at, .base = plan.base, .origin = plan.base, .origin_checkpoint = origin_cp },
    };
    return ticket;
}

pub fn checkpointAtOrBefore(
    session: *api.Session,
    cursor: seek_engine.Position,
    checkpoints: []const seek_engine.Checkpoint,
) ?seek_engine.Base {
    var best: ?seek_engine.Base = null;
    for (checkpoints) |c| {
        const cmp = session.comparePositions(c.position, cursor) catch continue;
        if (cmp == .gt) continue;
        if (best == null or c.position.r > best.?.checkpoint.position.r) {
            best = .{ .checkpoint = .{ .id = c.id, .object = c.object, .position = c.position } };
        }
    }
    return best;
}

pub fn restoreOrigin(self: *Transport, back: *const Back) void {
    restoreOriginPair(self, back.origin, back.origin_checkpoint);
}

pub fn restoreOriginPair(self: *Transport, origin: seek_engine.Base, fallback_cp: ?seek_engine.Base) void {
    switch (origin) {
        .current => {},
        .checkpoint => self.restoreBase(origin) catch {},
        .window => |win| {
            if (self.session.window) |w| {
                if (w.ready() and w.covers(win.position)) {
                    walkWindowTo(self.session, w, win.position) catch {};
                    return;
                }
            }
            if (fallback_cp) |cp| self.restoreBase(cp) catch {};
        },
    }
}

fn walkWindowTo(session: *api.Session, w: *@import("../history/window_engine.zig").ReverseWindow, target: seek_engine.Position) !void {
    while (w.cursor() > 0) {
        const at = w.at() orelse break;
        if ((session.comparePositions(at, target) catch break) != .gt) break;
        _ = try w.undo();
    }
    while (w.cursor() < w.count()) {
        const at = w.at() orelse break;
        if ((session.comparePositions(at, target) catch break) != .lt) break;
        _ = try w.redo();
    }
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
    defer self.session.setReplaying(false);
    self.session.setReplaying(true);
    const back = &job.back.?;
    // A machine that never stopped with no checkpoint in the log
    // stands at the history's beginning already: nothing to
    // restore, no earlier slot, so the step settles at once.
    if (back.target == null and back.start) return .{ .stop = .history_start };
    if (back.rebuilding) {
        _ = back_window.stepBuild(self, back);
        return null;
    }
    if (back.base == .window) {
        const w = self.session.window orelse return Error.NotReady;
        const canonical = @import("../history/canonical_step.zig");
        const core: @import("../history/trail.zig").Core = switch (job.core) {
            .cpu0 => .cpu0,
            .cpu1 => .cpu1,
        };
        _ = canonical.stepBack(w, core) catch |err| {
            if (err == canonical.Error.OutsideWindow) {
                return outsideWindowFallback(self, w, back);
            }
            return err;
        };
        job.left -= 1;
        if (self.session.grid) |g| back.cursor = g.at;
        if (job.left == 0) return .{ .stop = .stepped };
        return null;
    }
    if (!back.restored) {
        try self.restoreBase(back.base);
        back.restored = true;
        return null;
    }
    if (!back.windowed and back.base == .checkpoint) {
        if (back_window.beginBuild(self, job, back)) return null;
        back.restored = false;
        return null;
    }
    const grid = self.session.grid orelse return error.NoGrid;
    if (back.target == null) {
        return discoverPass(self, job, back, grid);
    }
    return landPass(self, job, back, grid);
}

fn outsideWindowFallback(
    self: *Transport,
    w: *@import("../history/window_engine.zig").ReverseWindow,
    back: *Back,
) ?api.Ended {
    const bridge = self.history orelse return .{ .stop = .history_start };
    var facts = bridge.facts(bridge.context) catch return .{ .stop = .history_start };
    if (self.session.fork_router) |router| {
        facts.graph = router.graph;
        facts.active_line = router.active_line;
    }
    const cur_pos = if (self.session.grid) |g| g.at else back.cursor;
    const win_bound = w.hot_at orelse w.start();
    var earlier_win: ?seek_engine.Base = null;
    var earlier_cur: ?seek_engine.Base = null;
    for (facts.checkpoints) |c| {
        const entry: seek_engine.Base = .{ .checkpoint = .{ .id = c.id, .object = c.object, .position = c.position } };
        if (win_bound) |bound| {
            if ((self.session.comparePositions(c.position, bound) catch .gt) == .lt) {
                if (earlier_win == null or c.position.r > earlier_win.?.checkpoint.position.r) earlier_win = entry;
            }
        }
        if ((self.session.comparePositions(c.position, cur_pos) catch .gt) == .lt) {
            if (earlier_cur == null or c.position.r > earlier_cur.?.checkpoint.position.r) earlier_cur = entry;
        }
    }
    const chosen = earlier_win orelse earlier_cur orelse return .{ .stop = .history_start };
    back.base = chosen;
    back.cursor = cur_pos;
    back.restored = false;
    back.windowed = earlier_win == null;
    back.rebuilding = false;
    back.target = null;
    back.seen = null;
    return null;
}

fn discoverPass(self: *Transport, job: *Job, back: *Back, grid: anytype) !?api.Ended {
    const before = self.session.comparePositions(grid.at, back.cursor) catch return error.OtherLine;
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
    const ended = try run_slice.stepReplaySlot(self.session);
    const after = self.session.comparePositions(grid.at, back.cursor) catch return error.OtherLine;
    if (after == .lt and grid.at.phase == corePhase(job.core)) back.seen = grid.at;
    if (ended == .count) return null;
    return ended;
}

fn landPass(self: *Transport, job: *Job, back: *Back, grid: anytype) !?api.Ended {
    const ord = self.session.comparePositions(grid.at, back.target.?) catch return error.OtherLine;
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
    const ended = try run_slice.stepReplaySlot(self.session);
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
