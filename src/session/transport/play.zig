//! The transport's play and continue queueing and slice execution.

const std = @import("std");
const api = @import("../api.zig");
const command_mod = @import("command.zig");
const debug_session = @import("../session.zig");
const session_speed = @import("../speed.zig");
const transport_mod = @import("transport.zig");

const Transport = transport_mod.Transport;
const Job = transport_mod.Job;
const Error = command_mod.Error;
const Ticket = command_mod.Ticket;

/// Validate, pace and queue a play or continue job.
pub fn queue(self: *Transport, speed: ?f64, kind: Job.Kind) !Ticket {
    const change = session_speed.Change.of(speed, debug_session.limits.default_budget) catch return Error.InvalidSpeed;
    const core = self.session.currentCore();
    const prior = transport_mod.budgetOf(self.session, core);
    self.cancel();
    self.epoch += 1;
    try self.session.setRunBudget(core, change.budget);
    const ticket = self.issue();
    self.job = .{
        .ticket = ticket,
        .epoch = self.epoch,
        .core = core,
        .kind = kind,
        .prior_budget = prior,
        .budget = change.budget,
        .dir = .fwd,
        .speed = speed,
    };
    return ticket;
}

/// Drive one play or continue slice at the session's run budget.
pub fn slice(self: *Transport, job: *Job) !?api.Ended {
    const ended = try self.session.run(job.core, .cont);
    if (ended == .count) return null;
    return ended;
}
