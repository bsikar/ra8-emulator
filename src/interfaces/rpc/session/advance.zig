//! The `advance` request (RA8EMU-654): run a core until the board's virtual
//! time has moved by a duration, or something stopped it first. The server
//! does the arithmetic, so a client never has to know the board's rate.
//!
//! Each round runs as many instructions as the time base says reach the
//! target: under the debugger the board charges one cycle per instruction
//! (src/session/board/boundary.zig). A rate the firmware changes mid-round
//! can leave the target short, so the next round runs the rest; a round
//! that moves no time ends it. A sleeping core goes by in wide chunks
//! (RA8EMU-767), so minutes of sleep cost about a host second.
//!
//! Time here is the session's: the board's closed time plus what the open
//! stretch has saved. A run that returns on its budget saves its progress
//! and leaves the board unticked, so the board's own clock alone would read
//! an advance inside one stretch as no time at all.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const proto = @import("rpc.zig");
const handlers = @import("handlers.zig");
const api = @import("ra8_session").api;

const Outcome = rpc.Outcome(proto.Advanced);

/// Rounds one advance may take before it reports where it got to.
const max_rounds = 64;

pub fn advance(context: *handlers.Context, args: proto.Advance) Outcome {
    if (args.ns == 0) return .{ .err = .bad_args };
    const session = context.session;
    const which: api.Core = @fromBackingInt(@intCast(@backingInt(args.core)));
    const from = session.now() catch |err| return refuse(err);
    const target = std.math.add(u64, from, args.ns) catch return .{ .err = .bad_args };
    const kept = budgetOf(session, which) catch |err| return refuse(err);
    const ended = rounds(session, which, target) catch |err| {
        session.setRunBudget(which, kept) catch {};
        return refuse(err);
    };
    session.setRunBudget(which, kept) catch |err| return refuse(err);
    const stop = handlers.stopped(session, args.core, ended);
    context.pending = stop;
    const to = session.now() catch |err| return refuse(err);
    return .{ .ok = .{ .core = args.core, .from_ns = from, .to_ns = to, .reason = stop.reason, .address = stop.address } };
}

/// Run until session time reaches `target`, a stop, or a round that moves no time.
fn rounds(session: *api.Session, which: api.Core, target: u64) !api.Ended {
    const base = session.time_base.?;
    for (0..max_rounds) |_| {
        const left = base.cyclesUntil(target) -| saved(session);
        if (left == 0) break;
        const before = try session.now();
        try session.setRunBudget(which, left);
        const ended = try session.run(which, .cont);
        if (ended != .count or try session.now() == before) return ended;
    }
    return .count;
}

/// Cycles the open stretch has saved, which the board's closed time lacks.
fn saved(session: *const api.Session) u64 {
    const grid = session.grid orelse return 0;
    return grid.stretch.carry;
}

/// The run budget `which` holds now, whether it has the session or is parked.
fn budgetOf(session: *const api.Session, which: api.Core) !u64 {
    const live = &session.live;
    if (live.index == @backingInt(which)) return live.budget;
    const parked = live.other orelse return error.CoreNotAttached;
    return parked.budget;
}

fn refuse(err: anyerror) Outcome {
    if (err == error.CoreNotAttached) return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.no_core)) };
    return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
}
