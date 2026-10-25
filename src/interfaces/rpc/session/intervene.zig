//! Console keystrokes and Skip BKPT from a remote front end (time-travel
//! design section 11). Both go through the Session's intervention choke
//! point, so in the recorded past they fork like a write does: the first
//! fork of a session refuses until branch_confirm_fork confirms it.
const rpc = @import("ra8_rpc_wire");
const proto = @import("rpc.zig");
const handlers = @import("handlers.zig");
const api = @import("ra8_session").api;

const AckOutcome = rpc.Outcome(proto.Ack);

/// Bytes typed into the board's console UART.
pub const ConsoleInput = struct {
    core: proto.Core,
    bytes: []const u8,
    pub const max_len = .{ .bytes = 4096 };
};

pub fn consoleInput(context: *handlers.Context, args: ConsoleInput) AckOutcome {
    context.session.consoleInput(core(args.core), args.bytes) catch |err| return refuse(err);
    return .{ .ok = .{ .accepted = 1 } };
}

/// Steps the core's PC over the BKPT it is stopped on.
pub fn skipBkpt(context: *handlers.Context, args: proto.CoreOnly) AckOutcome {
    context.session.skipBkpt(core(args.core)) catch |err| return refuse(err);
    return .{ .ok = .{ .accepted = 1 } };
}

fn core(of: proto.Core) api.Core {
    return @fromBackingInt(@intCast(@backingInt(of)));
}

fn refuse(err: anyerror) AckOutcome {
    const value = switch (err) {
        error.CoreNotAttached => handlers.app_codes.no_core,
        error.NoHistory => handlers.app_codes.history,
        else => handlers.app_codes.refused,
    };
    return .{ .err = @fromBackingInt(@intCast(value)) };
}
