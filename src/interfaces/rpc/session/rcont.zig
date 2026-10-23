//! The `rcont` request (RA8EMU-1196, this slice): a served host queues a
//! reverse-continue on the transport plane (design 2.4). The wire carries
//! no target: the transport drives the session's focused core. The plane's
//! own refusals are the live errors: a host without a bridge, a pending
//! base plan, an armed watchpoint, a broken history read.
const rpc = @import("ra8_rpc_wire");
const proto = @import("rpc.zig");
const handlers = @import("handlers.zig");

const Outcome = rpc.Outcome(proto.Ack);

pub fn rcont(context: *handlers.Context, args: proto.CoreOnly) Outcome {
    _ = args;
    const plane = context.transport orelse return refuse();
    _ = plane.command(.{ .rcont = {} }) catch |err| switch (err) {
        error.HistoryBroken => return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.history)) },
        else => return refuse(),
    };
    return .{ .ok = .{ .accepted = 1 } };
}

fn refuse() Outcome {
    return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
}
