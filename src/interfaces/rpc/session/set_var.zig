//! RPC handler for `Method.set_var` (0x013D): delegates symbol/DWARF variable
//! resolution and write mutation to `ra8_session.var_write`.
const rpc = @import("ra8_rpc_wire");
const ra8_session = @import("ra8_session");
const api = ra8_session.api;
const var_write = ra8_session.var_write;
const handlers = @import("handlers.zig");
const wire = @import("set_var_wire.zig");
const Context = @import("server.zig").Context;

pub const SetVarOutcome = rpc.Outcome(wire.SetVarReply);

pub fn setVar(context: *Context, request: wire.SetVarArgs) SetVarOutcome {
    const which: api.Core = if (request.core == .cpu0) .cpu0 else .cpu1;
    const image = handlers.imageOf(context, which) orelse return .{ .ok = .{
        .status = .frame_unavailable,
        .scope = .none,
        .address = 0,
        .in_register = 0xff,
        .size = 0,
        .message = "no firmware image loaded on core",
    } };

    const result = var_write.set(context.session, which, image, request.frame, request.name, request.value) catch {
        return .{ .err = @fromBackingInt(@intCast(handlers.app_codes.refused)) };
    };
    return .{ .ok = .{
        .status = mapStatus(result.status),
        .scope = mapScope(result.scope),
        .address = result.address,
        .in_register = result.in_register,
        .size = result.size,
        .message = result.message,
    } };
}

fn mapStatus(s: var_write.Status) wire.SetVarStatus {
    return switch (s) {
        .ok => .ok,
        .unknown_variable => .unknown_variable,
        .no_dwarf => .no_dwarf,
        .read_only => .read_only,
        .invalid_value => .invalid_value,
        .overflow => .overflow,
        .unsupported_type => .unsupported_type,
        .frame_unavailable => .frame_unavailable,
        .write_failed => .write_failed,
    };
}

fn mapScope(s: var_write.Scope) wire.SetVarScope {
    return switch (s) {
        .none => .none,
        .global => .global,
        .local => .local,
    };
}
