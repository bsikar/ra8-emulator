//! The transport's reverse-continue machinery: a backward search over the
//! recorded path for the latest breakpoint or fault behind the run, or the
//! latest write on an armed write watch (watch_search.zig).
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
const reverse_watch = @import("../history/reverse_watch.zig");
const watch_search = @import("watch_search.zig");

const Transport = transport_mod.Transport;
const Job = transport_mod.Job;
const Error = command_mod.Error;
const Ticket = command_mod.Ticket;

/// A reverse-continue's plan: the backward search's cursor, the
/// interval being replayed, and the two passes' state.
pub const Rc = struct {
    cursor: seek_engine.Position,
    upper: seek_engine.Position,
    base: seek_engine.Base,
    prior: ?seek_engine.Base = null,
    restored: bool = false,
    found: ?seek_engine.Position = null,
    landing: bool = false,
    landing_restored: bool = false,
    start: bool = false,
    origin: seek_engine.Base,
    has_watch: bool = false,
    range: reverse_watch.Range = .{ .address = 0, .size = 0 },
    watch_hit: ?reverse_watch.Hit = null,

    pub fn note(self: *Rc, position: seek_engine.Position, session: *api.Session) void {
        const newer = if (self.found) |found| blk: {
            const order = session.comparePositions(position, found) catch break :blk true;
            break :blk order == .gt;
        } else true;
        if (newer) self.found = position;
    }
};

/// Validate, plan and queue a reverse-continue against the bound history bridge.
pub fn queue(self: *Transport) !Ticket {
    const bridge = self.history orelse return Error.NotReady;
    var facts = bridge.facts(bridge.context) catch return Error.HistoryBroken;
    if (self.session.fork_router) |router| {
        facts.graph = router.graph;
        facts.active_line = router.active_line;
    }
    const core = self.session.currentCore();
    const prior = transport_mod.budgetOf(self.session, core);
    const watch_range = watch_search.armedWriteRange(self.session);
    if (self.session.grid == null) {
        self.cancel();
        self.epoch += 1;
        const ticket = self.issue();
        self.job = .{
            .ticket = ticket,
            .epoch = self.epoch,
            .core = core,
            .kind = .rcont,
            .prior_budget = prior,
            .rc = .{
                .cursor = .{},
                .upper = .{},
                .base = .current,
                .prior = null,
                .start = true,
                .origin = .current,
                .has_watch = watch_range != null,
                .range = watch_range orelse .{ .address = 0, .size = 0 },
            },
        };
        return ticket;
    }
    const grid = self.session.grid.?;
    const plan = switch (seek_engine.backBase(grid.at, facts)) {
        .plan => |plan| plan,
        .pending => return Error.NotReady,
    };
    const base = plan.base;
    const earlier = try earlierCheckpoint(self.session, base, grid.at, facts.checkpoints);
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
        .rc = .{
            .cursor = grid.at,
            .upper = grid.at,
            .base = base,
            .prior = earlier,
            .origin = base,
            .has_watch = watch_range != null,
            .range = watch_range orelse .{ .address = 0, .size = 0 },
        },
    };
    return ticket;
}

fn earlierCheckpoint(
    session: *api.Session,
    base: seek_engine.Base,
    cursor: seek_engine.Position,
    checkpoints: []const seek_engine.Checkpoint,
) !?seek_engine.Base {
    const target_pos = switch (base) {
        .current => return Error.NotReady,
        .checkpoint => |checkpoint| checkpoint.position,
        .window => cursor,
    };
    var earlier: ?seek_engine.Base = null;
    for (checkpoints) |c| {
        const before = session.comparePositions(c.position, target_pos) catch continue;
        if (before != .lt) continue;
        const better = earlier == null or c.position.r > earlier.?.checkpoint.position.r;
        if (better) earlier = .{ .checkpoint = .{ .id = c.id, .object = c.object, .position = c.position } };
    }
    return earlier;
}

/// Drive one reverse-continue in two passes over the committed log.
pub fn slice(self: *Transport, job: *Job) !?api.Ended {
    defer self.session.setReplaying(false);
    self.session.setReplaying(true);
    const rc = &job.rc.?;
    if (rc.start) return .{ .stop = .history_start };
    const grid = self.session.grid orelse return error.NoGrid;
    if (rc.landing) return landingSlice(self, job, rc, grid);
    // An armed watch searches by replay over the checkpoint intervals: the
    // window's undo only sees breakpoints, so it would miss a watch hit.
    if (rc.has_watch) return watch_search.watchSearchSlice(self, rc);
    if (rc.base == .window) {
        if (self.session.window) |w| {
            while (w.cursor() > 0) {
                _ = try w.undo();
                const at = self.session.grid orelse return error.NoGrid;
                if (rcBaseHit(self, at.at)) {
                    return try rcHitStop(self, at.at.phase);
                }
            }
        }
        if (rc.prior) |earlier| {
            return fallback(self, rc, earlier);
        }
        return .{ .stop = .history_start };
    }
    if (!rc.restored) {
        try self.restoreBase(rc.base);
        rc.restored = true;
        // A base that itself sits at an armed breakpoint is a hit at
        // the base's position: the replay's first resume executes
        // through it, so ask the state before running.
        const before = self.session.comparePositions(grid.at, rc.cursor) catch return error.OtherLine;
        if (before == .lt and rcBaseHit(self, grid.at)) rc.note(grid.at, self.session);
        return null;
    }
    const before = self.session.comparePositions(grid.at, rc.upper) catch return error.OtherLine;
    if (before != .lt) {
        if (rc.found != null) {
            rc.landing = true;
            rc.landing_restored = false;
            return null;
        }
        if (rc.prior) |earlier| return fallback(self, rc, earlier);
        try self.restoreBase(rc.base);
        return .{ .stop = .history_start };
    }
    const ended = try self.session.run(job.core, .cont);
    if (ended == .count) return null;
    const at = self.session.comparePositions(grid.at, rc.cursor) catch return error.OtherLine;
    if (at == .lt) rc.note(grid.at, self.session);
    return null;
}

fn landingSlice(self: *Transport, job: *Job, rc: *Rc, grid: anytype) !?api.Ended {
    _ = job;
    if (!rc.landing_restored) {
        try self.restoreBase(rc.base);
        rc.landing_restored = true;
        return null;
    }
    if (rc.watch_hit != null) return watch_search.landingSlice(self, rc, grid);
    const found = rc.found orelse return error.NoHit;
    const at = self.session.comparePositions(grid.at, found) catch return error.OtherLine;
    if (at == .gt) return error.OtherLine;
    if (at == .eq) return try rcHitStop(self, found.phase);
    const target_core = if (grid.at.phase == .cpu1) api.Core.cpu1 else api.Core.cpu0;
    const ended = try self.session.run(target_core, .cont);
    if (ended == .count) {
        const after = self.session.comparePositions(grid.at, found) catch return error.OtherLine;
        if (after == .lt) return null;
        return error.OtherLine;
    }
    const landed = self.session.comparePositions(grid.at, found) catch return error.OtherLine;
    if (landed == .lt) return null;
    return ended;
}

pub fn fallback(self: *Transport, rc: *Rc, earlier: seek_engine.Base) !?api.Ended {
    const upper = switch (rc.base) {
        .checkpoint => |base| base.position,
        .current => return error.NoGrid,
        .window => |w| w.position,
    };
    const bridge = self.history orelse return Error.NotReady;
    const facts = bridge.facts(bridge.context) catch return Error.HistoryBroken;
    const next = try earlierCheckpoint(self.session, earlier, earlier.checkpoint.position, facts.checkpoints);
    rc.base = earlier;
    rc.upper = upper;
    rc.prior = next;
    rc.restored = false;
    return null;
}

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
