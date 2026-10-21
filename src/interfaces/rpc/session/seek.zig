//! The `seek` request (RA8EMU-1196, slice 17): a served host moves a core's
//! run position to a target the design names in section 2 (a virtual time,
//! a percent, a round-phase-position address, a frame or bookmark). The
//! wire carries the target as text, so the wire language stays one
//! language: the queue door parses it, and malformed text is bad_args on
//! the wire too.
//!
//! Today every well-formed seek refuses: a seek's execution waits on the
//! position-stop primitive and the committed-log bridge, so the door
//! answers NotReady and this file speaks that refusal until they land.
const rpc = @import("ra8_rpc_wire");
const proto = @import("rpc.zig");
const handlers = @import("handlers.zig");

const Outcome = rpc.Outcome(proto.Ack);

pub fn seek(context: *handlers.Context, args: proto.Seek) Outcome {
    if (context.transport) |plane| {
        _ = plane.command(.{ .seek = .{ .target = args.target } }) catch |err| {
            if (err == error.InvalidArgs) return .{ .err = .bad_args };
            return refuse();
        };
        // The door never accepts a seek today (NotReady), so nothing is
        // queued here; a ticket landing would mean the execution path
        // arrived and this handler needs its drive added.
        return refuse();
    }
    return refuse();
}

fn refuse() Outcome {
    return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
}
