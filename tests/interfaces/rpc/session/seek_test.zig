//! The seek request (RA8EMU-1196, slice 17): malformed target text is
//! bad_args, a well-formed target whose plan waits on the bridge or an
//! index is refused, and a planned seek is accepted on the transport.
const std = @import("std");
const ra8 = @import("ra8");

const seek = ra8.rpc.session.seek;
const seek_engine = ra8.session.history_seek_engine;
const Rig = @import("advance_rig.zig").Rig;

test "a malformed seek target is bad_args" {
    var rig = Rig{};
    try rig.open();
    defer rig.close();
    var plane = ra8.session.transport.Transport{ .session = &rig.session };
    rig.context.transport = &plane;
    const outcome = seek.seek(&rig.context, .{ .target = "1.5ns" });
    switch (outcome) {
        .ok => return error.TestUnexpectedResult,
        .err => |code| try std.testing.expectEqualStrings("bad_args", @tagName(code)),
    }
}

test "a well-formed seek target is refused while execution is pending" {
    var rig = Rig{};
    try rig.open();
    defer rig.close();
    var plane = ra8.session.transport.Transport{ .session = &rig.session };
    rig.context.transport = &plane;
    try std.testing.expect(seek.seek(&rig.context, .{ .target = "0.5s" }) == .err);
}

test "a seek without a transport plane is refused" {
    var rig = Rig{};
    try rig.open();
    defer rig.close();
    try std.testing.expect(seek.seek(&rig.context, .{ .target = "0.5s" }) == .err);
}

/// The smallest bridge that plans: the cursor sits where the test's
/// target names, with no checkpoints, so the plan replays the live
/// cursor forward.
const MinBridge = struct {
    current: seek_engine.Position = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired },

    fn facts(context: *anyopaque) anyerror!seek_engine.Facts {
        const self: *MinBridge = @ptrCast(@alignCast(context));
        return .{ .current = self.current, .checkpoints = &.{} };
    }

    fn restore(context: *anyopaque, object: []const u8) anyerror!void {
        _ = context;
        _ = object;
    }
};

test "a planned seek is accepted on the transport" {
    var rig = Rig{};
    try rig.open();
    defer rig.close();
    _ = try rig.session.run(.cpu0, .step);
    var bridge = MinBridge{};
    var plane = ra8.session.transport.Transport{
        .session = &rig.session,
        .history = .{ .context = &bridge, .facts = &MinBridge.facts, .restore = &MinBridge.restore },
    };
    rig.context.transport = &plane;
    const outcome = seek.seek(&rig.context, .{ .target = "1:cpu0:0:retired" });
    switch (outcome) {
        .ok => {},
        .err => |code| {
            std.debug.print("unexpected refusal: {s}\n", .{@tagName(code)});
            return error.TestUnexpectedResult;
        },
    }
}
