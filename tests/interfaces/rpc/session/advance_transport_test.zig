//! The advance tests over the transport plane (RA8EMU-1196, slice 14):
//! `advance` routes through a bound plane and answers the same reply,
//! an async advance queues and completes on the transport, and the
//! flag gates queueing. The shared rig lives in advance_rig.zig.
const std = @import("std");
const ra8 = @import("ra8");

const advance = ra8.rpc.session.advance;
const server = ra8.rpc.session.server;
const proto = ra8.rpc.session.rpc;
const Rig = @import("advance_rig.zig").Rig;
const FakeWall = @import("advance_rig.zig").FakeWall;
const period = @import("advance_rig.zig").period;

test "advance through the transport answers the same reply" {
    var legacy = Rig{};
    try legacy.open();
    defer legacy.close();
    const straight = try legacy.advanceBy(period);

    var through = Rig{};
    try through.open();
    defer through.close();
    var plane = ra8.session.transport.Transport{ .session = &through.session };
    through.context.transport = &plane;
    var wall = FakeWall{};
    through.context.wall = .{ .context = &wall, .nowFn = FakeWall.now };
    const routed = try through.advanceBy(period);

    try std.testing.expectEqual(straight.from_ns, routed.from_ns);
    try std.testing.expectEqual(straight.to_ns, routed.to_ns);
    try std.testing.expectEqual(straight.reason, routed.reason);
    try std.testing.expectEqual(straight.address, routed.address);
}

test "an async advance queues and completes on the transport" {
    var rig = Rig{};
    try rig.open();
    defer rig.close();
    var plane = ra8.session.transport.Transport{ .session = &rig.session };
    rig.context.transport = &plane;
    var wall = FakeWall{};
    rig.context.wall = .{ .context = &wall, .nowFn = FakeWall.now };
    rig.context.transport_async = true;

    const queued = queuedBy(&rig.context, .{ .core = .cpu0, .ns = period }) orelse return error.Refused;
    const from = try rig.session.now();
    try std.testing.expectEqual(from, queued.from_ns);
    try std.testing.expectEqual(from + period, queued.target_ns);
    const ticket = rig.context.advance_ticket orelse return error.NoTicket;

    // The plane is on the job before any pump, and nothing has run yet.
    try std.testing.expectEqual(ra8.session.transport.Phase.advancing, plane.report().phase);
    try std.testing.expectEqual(from, try rig.session.now());

    // Host.poll's bounded pumps drive it to the target and the completion
    // is the queueing connection's ticket.
    // One window per pump: the wall read inside `drive` consumes the first
    // millisecond, so the deadline needs a margin over the pre-read value.
    while (plane.job != null and wall.ns < 60_000_000_000) {
        _ = try plane.pump(.{ .context = &wall, .nowFn = FakeWall.now }, wall.ns + 2_000_000);
    }
    const done = plane.done orelse return error.NoFinish;
    try std.testing.expectEqual(ticket, done.ticket);
    try std.testing.expectEqual(from + period, try rig.session.now());
    try std.testing.expect(rig.context.advance_ticket != null); // still owed until poll sends it
}

test "advance_async refuses without the plane or the flag" {
    var rig = Rig{};
    try rig.open();
    defer rig.close();
    try std.testing.expect(queuedBy(&rig.context, .{ .core = .cpu0, .ns = period }) == null);
    var plane = ra8.session.transport.Transport{ .session = &rig.session };
    rig.context.transport = &plane;
    var wall = FakeWall{};
    rig.context.wall = .{ .context = &wall, .nowFn = FakeWall.now };
    // The plane without the async flag refuses too: `serve` keeps the
    // blocking contract.
    try std.testing.expect(queuedBy(&rig.context, .{ .core = .cpu0, .ns = period }) == null);
    try std.testing.expect(plane.job == null);
}

/// The queued reply, or null when the handler refused.
fn queuedBy(context: *server.Context, args: proto.Advance) ?proto.AdvanceQueued {
    return switch (advance.advanceQueued(context, args)) {
        .ok => |moved| moved,
        .err => null,
    };
}
