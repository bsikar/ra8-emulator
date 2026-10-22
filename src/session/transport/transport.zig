//! The session's control plane (time-travel design section 3): one
//! single-threaded transport that fronts the Session's data plane for the
//! GUI, CLI, GDB and RPC alike.
//!
//! `command` validates and queues a job without running a core and hands
//! back a ticket; `pump` drives that job in bounded slices and never sleeps;
//! `report` carries phase, position, progress and epoch; `finish` is the
//! blocking helper a CLI or GDB loop calls with an injected wall and poll.
//! The newest command preempts the running job the way a Cancel would, so a
//! preempted job's ticket goes dead and its waiter gets Cancelled. Pause
//! stops at the gap the current slice ends on, so pause then play is
//! byte-identical to never pausing. A play's speed only changes scheduling:
//! it maps onto the run budget and never touches guest state.
//!
//! Seek and run-to are part of the command language. A seek's target text
//! is parsed at the door, so a malformed one is InvalidArgs, not a silent
//! refusal. With no history bridge bound a seek stays NotReady; with one
//! bound the transport plans it from the committed log's facts and
//! executes it: restore the chosen base's checkpoint object, then run
//! forward until the landing position, reached in the position's own
//! order (round, then phase, offset, gap), never before it within the
//! target's round. A run-to lands where a breakpoint would, which is its
//! own stop-ordering case, and stays NotReady.

const std = @import("std");
const api = @import("../api.zig");
const command_mod = @import("command.zig");
const debug_session = @import("../session.zig");
const session_speed = @import("../speed.zig");
const seek_target = @import("../history/seek_target.zig");
const position_mod = @import("../history/position.zig");
const seek_engine = @import("../history/seek_engine.zig");

pub const Command = command_mod.Command;
pub const Ticket = command_mod.Ticket;
pub const Phase = command_mod.Phase;
pub const Progress = command_mod.Progress;
pub const Report = command_mod.Report;
pub const State = command_mod.State;
pub const Pumped = command_mod.Pumped;
pub const Finished = command_mod.Finished;
pub const Wall = command_mod.Wall;
pub const Poll = command_mod.Poll;
pub const Error = command_mod.Error;

/// One blocking `finish` pump is at most this much host time between polls.
const finish_slice_ns: u64 = 50_000_000;

/// The committed-log bridge the application binds (RA8EMU-1196, unit 17):
/// how the transport reads the served history. Null keeps the seek
/// refusal; bound, a seek plans from the bridge's facts and executes
/// through it.
pub const Bridge = struct {
    context: *anyopaque,
    /// The committed log's facts for planning, gathered fresh per call.
    /// The bridge owns the returned memory until the next call.
    facts: *const fn (*anyopaque) anyerror!seek_engine.Facts,
    /// Put the machine back at a checkpoint's saved state. The name is
    /// the checkpoint record's 128-bit digest as its 32-hex object name.
    restore: *const fn (*anyopaque, object: []const u8) anyerror!void,
};

const Job = struct {
    ticket: Ticket,
    epoch: u64,
    core: api.Core,
    kind: Kind,
    /// Slices the job has driven so far.
    slices: u64 = 0,
    /// The budget the job replaced, put back when it ends or is preempted.
    prior_budget: u64 = 0,
    /// A play's per-run instruction budget; 0 leaves the session's alone.
    budget: u64 = 0,
    /// An advance's virtual target.
    target_ns: u64 = 0,
    /// A step's remaining instructions.
    left: u64 = 0,
    /// Where a play or continue moves; backward is refused until the
    /// history contracts land, so forward is the only value today.
    dir: command_mod.Direction = .fwd,
    /// A play's pace, when one was asked for; null is `max`.
    speed: ?f64 = null,
    /// A backward step's resolved plan, set when the job queues.
    back: ?Back = null,

    const Kind = union(enum) { play, cont, step, advance, seek: SeekKind };

    /// A seek job's resolved plan: where it lands and where its replay
    /// starts.
    const SeekKind = struct {
        /// The seek's landing position, phase included.
        target: seek_engine.Position,
        /// Where the replay starts.
        base: seek_engine.Base,
        /// Whether a checkpoint base's object is already restored.
        restored: bool = false,
        /// Wall moments and replay rounds the job's ETA rate comes from.
        rate: RateWindow = .{},
    };

    /// The two moments a seek's ETA divides by: the window's opening
    /// sample and the newest one. The opening sample slides forward
    /// whenever the span would outgrow the contract's five seconds, so
    /// the rate stays a recent one.
    const RateWindow = struct {
        window_wall_ns: u64 = 0,
        window_r: u64 = 0,
        last_wall_ns: u64 = 0,
        last_r: u64 = 0,
        has: bool = false,
    };

    /// A backward step's plan: the cursor it backs off from, the
    /// checkpoint base its replay starts from, and the two passes'
    /// state: discover the stop before the cursor, then land on it.
    const Back = struct {
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
};

/// The state payload a job reports with, from the payloads it really
/// holds (section 2.1). Shared by the report and the read gate.
fn jobState(job: *const Job) command_mod.State {
    return switch (job.kind) {
        .play => .{ .playing = .{ .dir = job.dir, .speed = job.speed } },
        .cont => .{ .continuing = .{ .dir = job.dir } },
        .advance => .{ .advancing = .{ .target_ns = job.target_ns } },
        .step => .{ .stepping = .{ .core = job.core, .count = job.left, .dir = job.dir } },
        .seek => .{ .seeking = .{ .target = job.kind.seek.target } },
    };
}

pub const Transport = struct {
    session: *api.Session,
    epoch: u64 = 0,
    next_ticket: Ticket = 1,
    job: ?Job = null,
    /// The newest job that finished, so a late `finish` still answers.
    done: ?Finished = null,
    /// The bound history bridge (unit 17), when the application serves
    /// one. Null keeps a seek refused.
    history: ?Bridge = null,

    /// Validate and queue a command. Nothing runs until the next `pump`.
    pub fn command(self: *Transport, cmd: Command) !Ticket {
        switch (cmd) {
            .pause => {
                self.cancel();
                self.epoch += 1;
                return self.issue();
            },
            .cont => return self.queuePlay(null, .cont),
            .play => |play| {
                if (play.dir == .back) return Error.NotReady;
                return self.queuePlay(play.speed, .play);
            },
            .step => |step| {
                if (step.count == 0) return Error.InvalidArgs;
                if (step.dir == .back) {
                    if (self.history == null) return Error.NotReady;
                    const bridge = self.history orelse return Error.NotReady;
                    const facts = bridge.facts(bridge.context) catch return Error.HistoryBroken;
                    const prior = budgetOf(self.session, step.core);
                    if (self.session.grid == null) {
                        // The machine has never stopped: the cursor sits
                        // at or before every recorded checkpoint, so the
                        // step can only settle at the log's beginning.
                        const planned = switch (seek_engine.backBaseAtStart(facts)) {
                            .plan => |plan| plan,
                            .pending => null,
                        };
                        self.cancel();
                        self.epoch += 1;
                        // The replay recreates the recorded path one
                        // instruction at a time; wakes ride along.
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
                            // The log holds no checkpoint: the machine's
                            // initial state is the history's beginning.
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
                    const grid = self.session.grid.?;
                    const plan = switch (seek_engine.backBase(grid.at, facts)) {
                        .plan => |plan| plan,
                        .pending => return Error.NotReady,
                    };
                    self.cancel();
                    self.epoch += 1;
                    // The replay recreates the recorded path one
                    // instruction at a time; wakes ride along.
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
                const prior = budgetOf(self.session, step.core);
                self.cancel();
                self.epoch += 1;
                const ticket = self.issue();
                self.job = .{ .ticket = ticket, .epoch = self.epoch, .core = step.core, .kind = .step, .prior_budget = prior, .left = step.count, .dir = step.dir };
                return ticket;
            },
            .advance => |advance| {
                if (advance.ns == 0) return Error.InvalidArgs;
                const from = try self.session.now();
                const target = std.math.add(u64, from, advance.ns) catch return Error.InvalidArgs;
                const prior = budgetOf(self.session, advance.core);
                self.cancel();
                self.epoch += 1;
                const ticket = self.issue();
                self.job = .{ .ticket = ticket, .epoch = self.epoch, .core = advance.core, .kind = .advance, .prior_budget = prior, .target_ns = target };
                return ticket;
            },
            .seek => |seek| return self.queueSeek(seek.target),
            .run_to => return Error.NotReady,
        }
    }

    /// Validate, plan and queue a seek against the bound history bridge.
    fn queueSeek(self: *Transport, text: []const u8) !Ticket {
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
        const prior = budgetOf(self.session, core);
        self.cancel();
        self.epoch += 1;
        const ticket = self.issue();
        self.job = .{ .ticket = ticket, .epoch = self.epoch, .core = core, .kind = .{ .seek = .{ .target = pos, .base = plan.base } }, .prior_budget = prior };
        return ticket;
    }

    fn queuePlay(self: *Transport, speed: ?f64, kind: Job.Kind) !Ticket {
        const change = session_speed.Change.of(speed, debug_session.limits.default_budget) catch return Error.InvalidSpeed;
        const core = self.session.currentCore();
        const prior = budgetOf(self.session, core);
        self.cancel();
        self.epoch += 1;
        try self.session.setRunBudget(core, change.budget);
        const ticket = self.issue();
        self.job = .{ .ticket = ticket, .epoch = self.epoch, .core = core, .kind = kind, .prior_budget = prior, .budget = change.budget, .dir = .fwd, .speed = speed };
        return ticket;
    }

    fn issue(self: *Transport) Ticket {
        const ticket = self.next_ticket;
        self.next_ticket += 1;
        return ticket;
    }

    /// Preempt the running job the way a Cancel would: its ticket goes dead.
    fn cancel(self: *Transport) void {
        if (self.job) |job| {
            self.session.setRunBudget(job.core, job.prior_budget) catch {};
            // A backward job's cancel returns the machine to the origin
            // checkpoint it queued at, whatever its replay rebased to
            // meanwhile (the seek contract's cancel rule, prompt 17).
            if (job.back) |*back| switch (back.origin) {
                .current => {},
                .checkpoint => |base| if (self.history) |bridge| {
                    var name: [32]u8 = undefined;
                    objectName(base.object, &name);
                    bridge.restore(bridge.context, &name) catch {};
                },
            };
            self.job = null;
        }
    }

    /// Drive the queued job in slices bounded by the wall until `until_ns`,
    /// a stop, or the job's own end. Never sleeps.
    pub fn pump(self: *Transport, wall: Wall, until_ns: u64) !Pumped {
        var finished: ?Finished = null;
        if (self.job) |*job| finished = try self.drive(job, wall, until_ns);
        return .{ .report = self.report(), .finished = finished, .drain = self.drainNeeded() };
    }

    /// The transport state now, without running anything.
    pub fn report(self: *const Transport) Report {
        var progress: command_mod.Progress = .{};
        var phase: command_mod.Phase = .halted;
        var state: ?command_mod.State = null;
        if (self.job) |*job| {
            progress.slices = job.slices;
            if (job.kind == .advance) {
                progress.target_ns = job.target_ns;
                progress.reached_ns = self.session.now() catch null;
            }
            if (job.kind == .seek) {
                progress.target_position = job.kind.seek.target;
                progress.eta_ns = self.seekEta(job);
            }
            phase = switch (job.kind) {
                .play => .playing,
                .cont => .continuing,
                .advance => .advancing,
                .step => .stepping,
                .seek => .seeking,
            };
            state = jobState(job);
        }
        return .{
            .epoch = self.epoch,
            .phase = phase,
            .state = state,
            .position = if (self.session.grid) |grid| grid.at else null,
            .progress = progress,
        };
    }

    /// The read gate (the contract's "reads return busy{state}" while
    /// moving): the running job's state when a read must not touch the
    /// machine, null when it may. A job between slices is in flight; a
    /// queued job has driven no slice yet, so it has moved the machine
    /// nowhere and reads are free until its first pump.
    pub fn busy(self: *const Transport) ?command_mod.State {
        if (self.job) |*job| {
            if (job.slices == 0) return null;
            return jobState(job);
        }
        return null;
    }

    /// Block on one ticket until its job ends, polling between slices.
    /// A ticket that was preempted, or one the poll cancels, is Cancelled.
    pub fn finish(self: *Transport, ticket: Ticket, wall: Wall, poll: ?Poll) !api.Ended {
        while (true) {
            if (self.done) |done| {
                if (done.ticket == ticket) return done.ended;
            }
            if (self.job == null or self.job.?.ticket != ticket) return Error.Cancelled;
            const start = wall.nowFn(wall.context);
            _ = try self.pump(wall, start + finish_slice_ns);
            // The pump may have finished the job; only a live one interrupts.
            if (self.job == null or self.job.?.ticket != ticket) continue;
            if (poll) |p| {
                if (p.pollFn(p.context)) {
                    // The application wants the thread back: halt the core
                    // like a front end's interrupt and settle the job with
                    // that stop, so the machine is stopped and reported.
                    const stopped = try self.session.interrupt(self.job.?.core);
                    const job = &self.job.?;
                    const finished = self.settle(job, .{ .stop = stopped });
                    return finished.ended;
                }
            }
        }
    }

    fn drive(self: *Transport, job: *Job, wall: Wall, until_ns: u64) !?Finished {
        while (true) {
            const now_ns = wall.nowFn(wall.context);
            if (now_ns >= until_ns) break;
            const ended: ?api.Ended = switch (job.kind) {
                .play, .cont => try self.playSlice(job),
                .advance => try self.advanceSlice(job),
                .step => try self.stepSlice(job),
                .seek => try self.seekSlice(job),
            };
            job.slices += 1;
            if (job.kind == .seek) self.sampleSeekRate(job, now_ns);
            if (ended) |stop| return self.settle(job, stop);
        }
        return null;
    }

    fn playSlice(self: *Transport, job: *Job) !?api.Ended {
        const ended = try self.session.run(job.core, .cont);
        if (ended == .count) return null;
        return ended;
    }

    fn stepSlice(self: *Transport, job: *Job) !?api.Ended {
        if (job.dir == .back) return self.backSlice(job);
        const ended = try self.session.run(job.core, .step);
        job.left -= 1;
        const point = ended == .stop and ended.stop != .stepped;
        if (job.left == 0 or point) return ended;
        return null;
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
    fn backSlice(self: *Transport, job: *Job) !?api.Ended {
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
            const bridge = self.history orelse return Error.NotReady;
            switch (back.base) {
                .current => {},
                .checkpoint => |base| {
                    var name: [32]u8 = undefined;
                    objectName(base.object, &name);
                    try bridge.restore(bridge.context, &name);
                },
            }
            back.restored = true;
            return null;
        }
        const grid = self.session.grid orelse return error.NoGrid;
        if (back.target == null) {
            const before = position_mod.compare(grid.at, back.cursor) catch return error.OtherLine;
            if (before == .gt) {
                const target = back.seen orelse {
                    // The log's beginning: no earlier canonical stop on
                    // this core's retire path. The base is the earliest
                    // provable state, so rest there and say so.
                    const bridge = self.history orelse return Error.NotReady;
                    switch (back.base) {
                        .current => {},
                        .checkpoint => |base| {
                            var name: [32]u8 = undefined;
                            objectName(base.object, &name);
                            try bridge.restore(bridge.context, &name);
                        },
                    }
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

    fn advanceSlice(self: *Transport, job: *Job) !?api.Ended {
        const session = self.session;
        const before = try session.now();
        const base = session.time_base orelse return error.NoTime;
        const left = base.cyclesUntil(job.target_ns) -| saved(session);
        if (left == 0) return reached();
        try session.setRunBudget(job.core, left);
        const ended = try session.run(job.core, .cont);
        if (ended != .count) return ended;
        const after = try session.now();
        if (after == before) return reached(); // a round that moves no time ends it
        if (after >= job.target_ns) return reached();
        return null;
    }

    /// Drive one seek slice: restore a checkpoint base once, then run
    /// forward until the landing position. The landing is phase-precise:
    /// the first check whose position has reached the target's, in the
    /// position's own order, ends the seek there; a check earlier in the
    /// target's round keeps running. A stop the run meets on the way
    /// settles the seek with it, the way a play's does.
    fn seekSlice(self: *Transport, job: *Job) !?api.Ended {
        const seek_job = &job.kind.seek;
        switch (seek_job.base) {
            .current => {},
            .checkpoint => |base| if (!seek_job.restored) {
                const bridge = self.history orelse return Error.NotReady;
                var name: [32]u8 = undefined;
                objectName(base.object, &name);
                try bridge.restore(bridge.context, &name);
                seek_job.restored = true;
                return null;
            },
        }
        const grid = self.session.grid orelse return error.NoGrid;
        const ord = position_mod.compare(grid.at, seek_job.target) catch return error.OtherLine;
        if (ord != .lt) return reached();
        const ended = try self.session.run(job.core, .cont);
        if (ended != .count) return ended;
        return null;
    }

    /// Fold one seek slice into the job's rate window: the slice's
    /// opening wall moment paired with the round the slice ended on.
    /// The window slides when it outgrows five seconds.
    fn sampleSeekRate(self: *const Transport, job: *Job, wall_ns: u64) void {
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
    fn seekEta(self: *const Transport, job: *const Job) ?u64 {
        const s = &job.kind.seek.rate;
        if (!s.has) return null;
        const wall = s.last_wall_ns -| s.window_wall_ns;
        const rounds = s.last_r -| s.window_r;
        if (wall == 0 or rounds == 0) return null;
        const grid = self.session.grid orelse return null;
        const remaining = job.kind.seek.target.r -| grid.at.r;
        const eta = @as(u128, remaining) * @as(u128, wall) / @as(u128, rounds);
        return @intCast(@min(eta, std.math.maxInt(u64)));
    }

    /// Close a finished job: put its budget back, forget it, and remember
    /// the result. The result is captured before the job is cleared, since
    /// the caller's pointer lives inside the optional being cleared.
    fn settle(self: *Transport, job: *Job, ended: api.Ended) Finished {
        const finished: Finished = .{ .ticket = job.ticket, .epoch = job.epoch, .core = job.core, .ended = ended };
        self.session.setRunBudget(job.core, job.prior_budget) catch {};
        self.job = null;
        self.done = finished;
        return finished;
    }

    fn drainNeeded(self: *const Transport) bool {
        return self.session.event_stream.nearFull();
    }
};

/// The wall span a seek's ETA rate window covers before it slides.
const rate_window_ns: u64 = 5 * std.time.ns_per_s;

/// The position phase a core retires on.
fn corePhase(core: api.Core) position_mod.Phase {
    return switch (core) {
        .cpu0 => .cpu0,
        .cpu1 => .cpu1,
    };
}

/// A checkpoint record's 128-bit digest as its object name: the lowercase
/// hex the object space files carry (refs.zig's encoding).
fn objectName(digest: [16]u8, name: *[32]u8) void {
    for (digest, 0..) |byte, i| {
        _ = std.fmt.bufPrint(name[i * 2 ..][0..2], "{x:0>2}", .{byte}) catch unreachable;
    }
}

fn reached() ?api.Ended {
    const count: api.Ended = .count;
    return count;
}

/// The run budget `core` holds now, whether it has the session or is parked.
fn budgetOf(session: *const api.Session, core: api.Core) u64 {
    const live = &session.live;
    if (live.index == @backingInt(core)) return live.budget;
    const parked = live.other orelse return debug_session.limits.default_budget;
    return parked.budget;
}

/// Cycles the open stretch has saved, which the board's closed time lacks.
fn saved(session: *const api.Session) u64 {
    const grid = session.grid orelse return 0;
    return grid.stretch.carry;
}
