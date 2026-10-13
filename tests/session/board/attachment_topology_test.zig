//! Topology on the touch line: a faulted part keeps its own line across restore.
const std = @import("std");
const ra8 = @import("ra8");
const c = ra8.components;
const Rig = @import("attachments_test.zig").Rig;
const Plugs = ra8.session.board.plug.Plugs;
const Endpoint = c.endpoint.Endpoint;
const touch_at: Endpoint = .{ .i2c = .{ .line = .touch, .address = 0x36 } };

fn touched(rig: *Rig) ![2]u8 {
    var bytes: [2]u8 = undefined;
    const device = rig.board.wire.touchline.devices.find(0x36) orelse return error.Missing;
    try std.testing.expectEqual(@as(usize, 2), device.read(&bytes));
    return bytes;
}

/// The stuck bytes, then what the gauge itself serves once the fault clears.
fn expectTouchOnly(rig: *Rig, cleared: [2]u8) !void {
    try std.testing.expect(rig.board.wire.controller.devices.find(0x36) == null);
    try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5 }, &try touched(rig));
    try rig.faults.set(touch_at, null);
    try std.testing.expectEqualSlices(u8, &cleared, &try touched(rig));
}

test "attachment strict runtime touch line gauge under a fault keeps its line" {
    const live = try Rig.create();
    defer live.destroy();
    try live.plugs.set(touch_at, "max17048");
    live.board.wire.touchline.devices.find(0x36).?.write(c.max17048.reg.soc);
    try live.faults.set(touch_at, .{ .stuck = 0xa5 });
    var saved = try live.save();
    defer saved.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5 }, &try touched(live));
    try live.faults.set(touch_at, null);
    const cleared = try touched(live);
    try std.testing.expect(cleared[0] != 0xa5);
    try live.plugs.set(touch_at, null);
    try std.testing.expectError(error.Missing, touched(live));
    const fresh = try Rig.create();
    defer fresh.destroy();
    for ([_]*Rig{ live, fresh }) |target| {
        try target.restore(saved.written());
        try expectTouchOnly(target, cleared);
        try target.restore(saved.written());
        try expectTouchOnly(target, cleared);
    }
}

test "attachment strict startup touch line gauge under a fault restores and tears down" {
    const live = try Rig.create();
    defer live.destroy();
    const asks = [_]c.request.Request{.{ .name = "max17048", .at = touch_at, .fault = .{ .stuck = 0xa5 } }};
    live.board.asks.keep(live.arena.allocator(), &asks);
    try ra8.board.plug.all(&live.board);
    live.plugs = Plugs.init(&live.board, live.arena.allocator());
    try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5 }, &try touched(live));
    var saved = try live.save();
    defer saved.deinit();
    for (0..3) |_| {
        try live.restore(saved.written());
        try std.testing.expect(live.board.wire.controller.devices.find(0x36) == null);
        try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5 }, &try touched(live));
    }
}

test "attachment strict runtime fault on startup touch gauge keeps its owned line" {
    const live = try Rig.create();
    defer live.destroy();
    const asks = [_]c.request.Request{.{ .name = "max17048", .at = touch_at }};
    live.board.asks.keep(live.arena.allocator(), &asks);
    try ra8.board.plug.all(&live.board);
    live.plugs = Plugs.init(&live.board, live.arena.allocator());
    try live.faults.set(touch_at, .{ .stuck = 0xa5 });
    var graph: ra8.session.board.state.attachments.graph.Graph = .{};
    _ = try ra8.session.board.state.attachments.capture(&live.board, live.binding(), &graph);
    for (graph.nodes[0..graph.count]) |node| {
        if (node.kind == .part and node.kind.part == .gauge) try std.testing.expectEqualDeep(touch_at, node.at);
    }
    var saved = try live.save();
    defer saved.deinit();
    try live.restore(saved.written());
    try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5 }, &try touched(live));
    try live.faults.set(touch_at, null);
    try std.testing.expectEqualSlices(u8, &.{ 0xbe, 0 }, &try touched(live));
}
