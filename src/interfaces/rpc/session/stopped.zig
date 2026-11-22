//! Wire encoding helpers for session stop reports.
const api = @import("ra8_session").api;
const proto = @import("rpc.zig");
const std = @import("std");
const stop_machine = @import("ra8_session").stop_machine;

/// The wire form of how a run ended, on the core that ended it: a served
/// round can stop the other core than the one asked.
pub fn stopped(session: *api.Session, _: proto.Core, ended: api.Ended) proto.Stopped {
    return reported(session, @fromBackingInt(@intCast(session.live.ended_index)), ended);
}

/// The wire form of how a run of `of` ended, at the PC it left.
pub fn reported(session: *api.Session, of: proto.Core, ended: api.Ended) proto.Stopped {
    const which: api.Core = @fromBackingInt(@intCast(@backingInt(of)));
    const pc = session.register(which, .pc) catch 0;
    return switch (ended) {
        .count => .{ .core = of, .reason = .count, .address = pc, .detail = 0 },
        .core => |stop| .{
            .core = of,
            .reason = .core_fault,
            .address = pc,
            .detail = @backingInt(std.meta.activeTag(stop)),
        },
        .stop => |stop| .{ .core = of, .reason = reason(stop), .address = pc, .detail = detail(stop) },
    };
}

fn reason(stop: stop_machine.Stop) proto.StopReason {
    return std.meta.stringToEnum(proto.StopReason, @tagName(stop)) orelse .halt_requested;
}

fn detail(stop: stop_machine.Stop) u32 {
    return switch (stop) {
        .watchpoint => |hit| hit.id,
        .replay_failed => |failure| @backingInt(failure.source),
        inline else => |value| if (@typeInfo(@TypeOf(value)) == .int) @truncate(value) else 0,
    };
}
