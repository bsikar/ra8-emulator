//! The `rcont` request (RA8EMU-1196, this slice): a host without a bridge
//! is refused, and a host with a bound bridge queues the reverse-continue
//! job on the transport plane.
const std = @import("std");
const ra8 = @import("ra8");

const rcont = ra8.rpc.session.rcont;
const Rig = @import("advance_rig.zig").Rig;

test "an rcont without a transport plane is refused" {
    var rig = Rig{};
    try rig.open();
    defer rig.close();
    try std.testing.expect(rcont.rcont(&rig.context, .{ .core = .cpu0 }) == .err);
}

test "an rcont without a bridge is refused" {
    var rig = Rig{};
    try rig.open();
    defer rig.close();
    var plane = ra8.session.transport.Transport{ .session = &rig.session };
    rig.context.transport = &plane;
    try std.testing.expect(rcont.rcont(&rig.context, .{ .core = .cpu0 }) == .err);
}

test "an rcont with a bridge queues the reverse-continue job" {
    var rig = Rig{};
    try rig.open();
    defer rig.close();
    var bridge = MinBridge{};
    var plane = ra8.session.transport.Transport{
        .session = &rig.session,
        .history = .{ .context = &bridge, .facts = &MinBridge.facts, .restore = &MinBridge.restore },
    };
    rig.context.transport = &plane;
    const outcome = rcont.rcont(&rig.context, .{ .core = .cpu0 });
    switch (outcome) {
        .ok => try std.testing.expectEqual(ra8.session.transport.Phase.reverse_continuing, plane.report().phase),
        .err => |code| {
            std.debug.print("unexpected refusal: {s}\n", .{@tagName(code)});
            return error.TestUnexpectedResult;
        },
    }
}

/// The smallest bridge that plans: the cursor sits at the origin with no
/// checkpoints, so the reverse-continue settles at the history's start.
const MinBridge = struct {
    current: ra8.session.history_seek_engine.Position = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired },

    fn facts(context: *anyopaque) anyerror!ra8.session.history_seek_engine.Facts {
        const self: *MinBridge = @ptrCast(@alignCast(context));
        return .{ .current = self.current, .checkpoints = &.{} };
    }

    fn restore(context: *anyopaque, object: []const u8) anyerror!void {
        _ = context;
        _ = object;
    }
};
