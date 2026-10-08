//! Session events for subscribed clients (RA8EMU-942). The session event
//! stream (RA8EMU-192) already publishes every load, pause, stop, write,
//! breakpoint, speed change, scheduled input, fault switch and plug; this
//! drains its own queue and sends each kind the wire names as a `session`
//! event. Kinds with their own topic (uart, lcd) or no wire name are skipped.
const std = @import("std");
const proto = @import("session_rpc.zig");
const api = @import("../../debug/session_api.zig");
const Context = @import("session_handlers.zig").Context;

/// Events read from the stream per pass.
const batch = 64;

/// The wire kind of each stream kind, by the stream kind's value; built by
/// name, so a wire kind with no stream event fails the build.
const wire_kinds = table: {
    @setEvalBranchQuota(20_000);
    for (@typeInfo(proto.EventKind).@"enum".field_names) |name| {
        if (std.meta.stringToEnum(api.Event.Kind, name) == null) @compileError("no stream event for wire kind " ++ name);
    }
    const names = @typeInfo(api.Event.Kind).@"enum".field_names;
    var kinds: [names.len]?proto.EventKind = undefined;
    for (names, 0..) |name, index| kinds[index] = std.meta.stringToEnum(proto.EventKind, name);
    break :table kinds;
};

/// The wire kind a stream event goes out as, or null when the wire has none.
pub fn wireKind(kind: api.Event.Kind) ?proto.EventKind {
    return wire_kinds[@backingInt(kind)];
}

/// Send every queued session event a subscribed core produced through `server`.
pub fn pump(context: *Context, server: anytype, tx: []u8) !void {
    const id = context.session_feed orelse return;
    var events: [batch]api.Event = undefined;
    while (true) {
        const read = context.session.pollEvents(id, &events) orelse return;
        if (read.dropped != 0) std.debug.print("serve: {d} session events dropped before a client read them\n", .{read.dropped});
        for (events[0..read.count]) |event| {
            const kind = wireKind(event.kind) orelse continue;
            const of: proto.Core = @fromBackingInt(@intCast(@backingInt(event.core)));
            if (!context.wants(of, .session)) continue;
            const sent: proto.SessionEvent = .{ .core = of, .kind = kind, .address = event.address orelse 0 };
            try server.emit(proto.SessionEvent, @backingInt(proto.Topic.session), sent, tx);
        }
        if (read.count < batch) return;
    }
}
