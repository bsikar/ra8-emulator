//! Turbo advance machinery for src/interfaces/gui/shell/run.zig (slice 19).
const std = @import("std");
const proto = @import("ra8_rpc").session.rpc;
const session_link = @import("../session_link.zig");
const shell_run = @import("run.zig");

const Link = session_link.Link;
const Run = shell_run.Run;
const Seen = shell_run.Seen;

/// Start a turbo run (slice 19): queue an unpaced advance on the
/// transport that runs the board forward `ns` of virtual time and
/// completes on the transport topic, the way the spec's unrun tail
/// asks for. Only from a halted run: a lit run's slices and the
/// turbo's job would fight for the core. Needs a transport-capable
/// link: the job, its preemption and its records are the
/// transport's, and a plain link has no queue to hold a long one.
pub fn turbo(run: *Run, link: *Link, ns: u64) !void {
    if (run.lit or run.turbo_id != null or run.turbo_out) return error.NotReady;
    if (ns == 0) return error.NotReady;
    if (link.caps() & proto.transport_cap == 0) return error.NotReady;
    if (!run.subscribed) {
        _ = try link.send(proto.Subscription, .subscribe, .{ .core = run.core, .topic = .transport });
        run.subscribed = true;
    }
    run.turbo_id = try link.send(proto.Advance, .advance_async, .{ .core = run.core, .ns = ns });
}

pub fn observeResponse(run: *Run, response: anytype, now_ns: u64) ?Seen {
    const id = run.turbo_id orelse return null;
    if (response.id != id) return null;
    run.turbo_id = null;
    const queued: ?proto.AdvanceQueued = switch (response.result) {
        .ok => |bytes| proto.decode(proto.AdvanceQueued, bytes) catch null,
        .err => null,
    };
    if (queued == null) {
        run.turbo_refused = true;
    } else {
        run.turbo_out = true;
        run.turbo_target_ns = queued.?.target_ns;
        run.turbo_from_ns = queued.?.from_ns;
        run.turbo_started_wall_ns = now_ns;
        run.turbo_eta = null;
    }
    return .other;
}

pub fn observeTransport(run: *Run, done: proto.TransportEvent, now_ns: u64) ?Seen {
    if (!run.turbo_out) return null;
    // The turbo's own completion (slice 19): the job
    // landed where it got to. A pause that preempted it
    // hands its halt back through the settled path.
    // A progress event moves the board time and
    // re-derives the estimate from the rate so far;
    // the clock poll keeps the readout fresh (slice 19).
    if (done.finished != 1) {
        run.board_ns = done.reached_ns;
        const elapsed = now_ns -| run.turbo_started_wall_ns;
        const moved = done.reached_ns -| run.turbo_from_ns;
        if (elapsed != 0 and done.reached_ns > run.turbo_from_ns) {
            const rate: u128 = moved / elapsed;
            if (rate != 0) {
                const remaining = done.target_ns -| done.reached_ns;
                run.turbo_eta = @intCast(remaining / rate);
            }
        }
        return .other;
    }
    run.turbo_out = false;
    run.turbo_arrived = true;
    run.turbo_eta = null;
    run.turbo_target_ns = 0;
    run.turbo_from_ns = 0;
    run.turbo_started_wall_ns = 0;
    run.address = done.address;
    run.board_ns = done.to_ns;
    if (done.reason == .halt_requested) run.settled = done.address;
    return .slice;
}
