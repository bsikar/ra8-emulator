//! The transport's seek machinery: planning from the committed log's
//! facts, restore-and-replay execution, rate sampling and ETA estimation.
//!
//! A seek's target text is parsed at the door. With no history bridge
//! bound a seek stays NotReady; with one bound the transport plans it
//! from the committed log's facts and executes it: restore the chosen
//! base's checkpoint object, then run forward until the landing
//! position, reached in the position's own order (round, then phase,
//! offset, gap), never before it within the target's round.

const std = @import("std");
const api = @import("../api.zig");
const command_mod = @import("command.zig");
const seek_target = @import("../history/seek_target.zig");
const position_mod = @import("../history/position.zig");
const seek_engine = @import("../history/seek_engine.zig");
const transport_mod = @import("transport.zig");

const Transport = transport_mod.Transport;
const Job = transport_mod.Job;
const Error = command_mod.Error;
const Ticket = command_mod.Ticket;

/// The wall span a seek's ETA rate window covers before it slides.
pub const rate_window_ns: u64 = 5 * std.time.ns_per_s;

/// The two moments a seek's ETA divides by: the window's opening
/// sample and the newest one. The opening sample slides forward
/// whenever the span would outgrow the contract's five seconds, so
/// the rate stays a recent one.
pub const RateWindow = struct {
    window_wall_ns: u64 = 0,
    window_r: u64 = 0,
    last_wall_ns: u64 = 0,
    last_r: u64 = 0,
    has: bool = false,
};

/// A seek job's resolved plan: where it lands and where its replay
/// starts.
pub const SeekKind = struct {
    /// The seek's landing position, phase included.
    target: seek_engine.Position,
    /// Where the replay starts.
    base: seek_engine.Base,
    /// Whether a checkpoint base's object is already restored.
    restored: bool = false,
    /// Wall moments and replay rounds the job's ETA rate comes from.
    rate: RateWindow = .{},
};

/// Validate, plan and queue a seek against the bound history bridge.
pub fn queue(self: *Transport, text: []const u8) !Ticket {
    const target = seek_target.parse(text) catch return Error.InvalidArgs;
    const bridge = self.history orelse return Error.NotReady;
    // Only a position target executes today: the other kinds' plans
    // name the index their resolution still waits for, so they stay
    // refused until it lands.
    const pos: seek_engine.Position = switch (target) {
        .position => |pt| pt.position,
        else => return Error.NotReady,
    };
    const facts = bridge.facts(bridge.context) catch return Error.HistoryBroken;
    const plan = switch (seek_engine.plan(target, facts)) {
        .plan => |plan| plan,
        .pending => return Error.NotReady,
    };
    // A position target lands on the boundary grid; without one there
    // is nothing to land on.
    if (self.session.grid == null) return Error.InvalidArgs;
    const core = self.session.currentCore();
    const prior = transport_mod.budgetOf(self.session, core);
    self.cancel();
    self.epoch += 1;
    const ticket = self.issue();
    self.job = .{
        .ticket = ticket,
        .epoch = self.epoch,
        .core = core,
        .kind = .{ .seek = .{ .target = pos, .base = plan.base } },
        .prior_budget = prior,
    };
    return ticket;
}

/// Drive one seek slice: restore a checkpoint base once, then run
/// forward until the landing position. The landing is phase-precise:
/// the first check whose position has reached the target's, in the
/// position's own order, ends the seek there; a check earlier in the
/// target's round keeps running. A stop the run meets on the way
/// settles the seek with it, the way a play's does.
pub fn slice(self: *Transport, job: *Job) !?api.Ended {
    const seek_job = &job.kind.seek;
    switch (seek_job.base) {
        .current => {},
        .checkpoint => if (!seek_job.restored) {
            try self.restoreBase(seek_job.base);
            seek_job.restored = true;
            return null;
        },
    }
    const grid = self.session.grid orelse return error.NoGrid;
    const ord = position_mod.compare(grid.at, seek_job.target) catch return error.OtherLine;
    if (ord != .lt) return transport_mod.reached();
    self.session.setReplaying(true);
    defer self.session.setReplaying(false);
    const ended = try self.session.run(job.core, .cont);
    if (ended != .count) return ended;
    return null;
}

/// Fold one seek slice into the job's rate window: the slice's
/// opening wall moment paired with the round the slice ended on.
/// The window slides when it outgrows five seconds.
pub fn sampleRate(self: *const Transport, job: *Job, wall_ns: u64) void {
    const grid = self.session.grid orelse return;
    const s = &job.kind.seek.rate;
    const at_r = grid.at.r;
    if (!s.has) {
        s.* = .{ .window_wall_ns = wall_ns, .window_r = at_r, .last_wall_ns = wall_ns, .last_r = at_r, .has = true };
        return;
    }
    s.last_wall_ns = wall_ns;
    s.last_r = at_r;
    if (wall_ns - s.window_wall_ns > rate_window_ns) {
        s.window_wall_ns = wall_ns;
        s.window_r = at_r;
    }
}

/// A seek's arrival estimate: the rounds still to replay divided by
/// the replay rate the job's wall window measured. Null until the
/// window holds both a span and a round of movement, so a seek's
/// first reports and an instant restore-only replay carry none.
pub fn eta(self: *const Transport, job: *const Job) ?u64 {
    const s = &job.kind.seek.rate;
    if (!s.has) return null;
    const wall = s.last_wall_ns -| s.window_wall_ns;
    const rounds = s.last_r -| s.window_r;
    if (wall == 0 or rounds == 0) return null;
    const grid = self.session.grid orelse return null;
    const remaining = job.kind.seek.target.r -| grid.at.r;
    const eta_val = @as(u128, remaining) * @as(u128, wall) / @as(u128, rounds);
    return @intCast(@min(eta_val, std.math.maxInt(u64)));
}
