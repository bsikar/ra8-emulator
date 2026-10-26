//! The transport's play and continue queueing and slice execution.

const std = @import("std");
const api = @import("../api.zig");
const command_mod = @import("command.zig");
const debug_session = @import("../session.zig");
const session_speed = @import("../speed.zig");
const transport_mod = @import("transport.zig");
const line = @import("../line.zig");
const replay_feeder = @import("../history/replay_feeder.zig");

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

/// Drive one play or continue slice at the session's run budget. Inside
/// the recorded past the run replays (run_slice.zig) and re-applies the
/// line's interventions, which load once, due after the position the
/// machine already stands at.
pub fn slice(self: *Transport, job: *Job) !?api.Ended {
    if (self.session.window) |w| {
        if (w.cursor() < w.count()) {
            const count = @min(w.count() - w.cursor(), if (job.budget > 0) job.budget else 1000);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const cur = w.cursor();
                if (!try w.redo()) break;
                const m = self.session.machine(job.core) catch break;
                if (m.watches.len > 0) {
                    const payload = w.trail.slotAt(cur);
                    var tripped: ?@import("../watch/table.zig").Hit = null;
                    for (payload.byte_records) |rec| {
                        const addr: u32 = @intCast(rec.base + rec.offset);
                        const w_len: u8 = @intCast(@min(rec.data.len, 255));
                        if (m.watches.hit(addr, w_len, .write)) |hit| {
                            tripped = hit;
                            break;
                        }
                    }
                    if (tripped) |hit| {
                        return api.Ended{ .stop = .{ .watchpoint = hit } };
                    }
                }
                const pc = self.session.register(job.core, .pc) catch break;
                if (m.breaks.hit(pc)) |hit| {
                    return api.Ended{ .stop = .{ .breakpoint = hit } };
                }
            }
            if (w.cursor() < w.count()) return null;
        }
    }
    if (self.session.replay_feeder == null and line.inPast(self.session)) {
        if (self.history) |br| if (br.logBytes) |read| {
            try replay_feeder.loadSessionInterventions(self.session, try read(br.context), .after);
        };
    }
    const ended = try self.session.run(job.core, .cont);
    if (ended == .count) return null;
    return ended;
}
