//! The `seek` request (RA8EMU-1196, slice 17): a served host moves a core's
//! run position to a target the design names in section 2 (a virtual time,
//! a percent, a round-phase-position address, a frame or bookmark). The
//! wire carries the target as text, so the wire language stays one
//! language: the queue door parses it, and malformed text is bad_args on
//! the wire too.
//!
//! A well-formed seek whose target plans against the transport's bound
//! history bridge is queued on the transport and answered accepted; its
//! completion surfaces on the transport topic. A target whose resolution
//! waits on an index still to land plans pending, a host without a bridge
//! or a plane stays refused, and a history read failure answers the
//! app's history code (RA8EMU-1196).
const rpc = @import("ra8_rpc_wire");
const proto = @import("rpc.zig");
const handlers = @import("handlers.zig");

const Outcome = rpc.Outcome(proto.Ack);

pub fn seek(context: *handlers.Context, args: proto.Seek) Outcome {
    const plane = context.transport orelse return refuse();
    _ = plane.command(.{ .seek = .{ .target = args.target } }) catch |err| switch (err) {
        error.InvalidArgs => return .{ .err = .bad_args },
        error.HistoryBroken => return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.history)) },
        else => return refuse(),
    };
    return .{ .ok = .{ .accepted = 1 } };
}

fn refuse() Outcome {
    return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
}
