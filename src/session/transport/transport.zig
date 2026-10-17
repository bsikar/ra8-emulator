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
//! Seek and run-to are part of the command language but stay refused with
//! NotReady in this slice: seek's base needs the history contracts (units
//! 17/18), and a run-to lands where a breakpoint would, which is its own
//! stop-ordering case. Their types exist so front ends already speak them.

const std = @import("std");
const api = @import("../api.zig");
const command_mod = @import("command.zig");
const debug_session = @import("../session.zig");
const session_speed = @import("../speed.zig");

pub const Command = command_mod.Command;
pub const Ticket = command_mod.Ticket;
pub const Phase = command_mod.Phase;
pub const Progress = command_mod.Progress;
pub const Report = command_mod.Report;
pub const Pumped = command_mod.Pumped;
pub const Finished = command_mod.Finished;
pub const Wall = command_mod.Wall;
pub const Poll = command_mod.Poll;
pub const Error = command_mod.Error;

/// One blocking `finish` pump is at most this much host time between polls.
const finish_slice_ns: u64 = 50_000_000;

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

    const Kind = union(enum) { play, cont, step, advance };
};

pub const Transport = struct {
    session: *api.Session,
    epoch: u64 = 0,
    next_ticket: Ticket = 1,
    job: ?Job = null,
    /// The newest job that finished, so a late `finish` still answers.
    done: ?Finished = null,

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
                const prior = budgetOf(self.session, step.core);
                self.cancel();
                self.epoch += 1;
                const ticket = self.issue();
                self.job = .{ .ticket = ticket, .epoch = self.epoch, .core = step.core, .kind = .step, .prior_budget = prior, .left = step.count };
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
            .seek, .run_to => return Error.NotReady,
        }
    }

    fn queuePlay(self: *Transport, speed: ?f64, kind: Job.Kind) !Ticket {
        const change = session_speed.Change.of(speed, debug_session.limits.default_budget) catch return Error.InvalidSpeed;
        const core = self.session.currentCore();
        const prior = budgetOf(self.session, core);
        self.cancel();
        self.epoch += 1;
        try self.session.setRunBudget(core, change.budget);
        const ticket = self.issue();
        self.job = .{ .ticket = ticket, .epoch = self.epoch, .core = core, .kind = kind, .prior_budget = prior, .budget = change.budget };
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
        if (self.job) |job| {
            progress.slices = job.slices;
            if (job.kind == .advance) {
                progress.target_ns = job.target_ns;
                progress.reached_ns = self.session.now() catch null;
            }
            phase = switch (job.kind) {
                .play => .playing,
                .cont => .continuing,
                .advance => .advancing,
                .step => .stepping,
            };
        }
        return .{
            .epoch = self.epoch,
            .phase = phase,
            .position = if (self.session.grid) |grid| grid.at else null,
            .progress = progress,
        };
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
        while (wall.nowFn(wall.context) < until_ns) {
            const ended: ?api.Ended = switch (job.kind) {
                .play, .cont => try self.playSlice(job),
                .advance => try self.advanceSlice(job),
                .step => try self.stepSlice(job),
            };
            job.slices += 1;
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
        const ended = try self.session.run(job.core, .step);
        job.left -= 1;
        const point = ended == .stop and ended.stop != .stepped;
        if (job.left == 0 or point) return ended;
        return null;
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
