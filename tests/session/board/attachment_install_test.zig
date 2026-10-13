//! Commit ownership: orphaned wrappers and faulted startup parts clean up.
const std = @import("std");
const ra8 = @import("ra8");
const c = ra8.components;
const Rig = @import("attachments_test.zig").Rig;
const Plugs = ra8.session.board.plug.Plugs;
const Endpoint = c.endpoint.Endpoint;
const gauge_at: Endpoint = .{ .i2c = .{ .line = .riic, .address = 0x36 } };
const panel_at: Endpoint = .{ .spi = .{ .channel = 1, .select = 2 } };
const modem_at: Endpoint = .{ .uart = .{ .channel = 3 } };

fn gauge(rig: *Rig) ![2]u8 {
    var bytes: [2]u8 = undefined;
    const device = rig.board.wire.controller.devices.find(0x36) orelse return error.Missing;
    try std.testing.expectEqual(@as(usize, 2), device.read(&bytes));
    return bytes;
}

test "attachment strict orphan cleared and displaced wrappers are replaced and cleaned up" {
    const rig = try Rig.create();
    defer rig.destroy();
    var empty = try rig.save();
    defer empty.deinit();
    try rig.plugs.set(gauge_at, "max17048");
    rig.board.wire.controller.devices.find(0x36).?.write(c.max17048.reg.soc);
    try rig.faults.set(gauge_at, .{ .stuck = 0xa5 });
    try rig.faults.set(gauge_at, null);
    try rig.plugs.set(panel_at, "eink");
    try rig.faults.set(panel_at, .{ .garbage = 987 });
    try rig.plugs.set(modem_at, "modem");
    try rig.faults.set(modem_at, .{ .garbage = 5 });
    try rig.plugs.set(gauge_at, null);
    try rig.plugs.set(panel_at, null);
    try rig.plugs.set(modem_at, null);
    var orphaned = try rig.save();
    defer orphaned.deinit();
    const kept = rig.plugs.instance_count;
    for ([_][]const u8{ empty.written(), orphaned.written(), orphaned.written(), empty.written() }, [_]usize{ 0, kept, kept, 0 }) |bytes, count| {
        try rig.restore(bytes);
        try std.testing.expectEqual(count, rig.plugs.instance_count);
        try std.testing.expectError(error.Missing, gauge(rig));
        try std.testing.expect(rig.board.serial.channels[3].device == null);
    }
    for (rig.faults.wrapped) |entry| try std.testing.expect(entry == null);
    for (rig.faults.spi_parts.held) |entry| try std.testing.expect(entry == null);
    for (rig.faults.uart_parts.held) |entry| try std.testing.expect(entry == null);
    try rig.plugs.set(gauge_at, "max17048");
    rig.board.wire.controller.devices.find(0x36).?.write(c.max17048.reg.soc);
    try std.testing.expectEqualSlices(u8, &.{ 72, 0 }, &try gauge(rig));
    try rig.faults.set(gauge_at, .{ .stuck = 0x11 });
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x11 }, &try gauge(rig));
}

test "attachment strict startup panel on a nonzero select under a fault restores and tears down" {
    const live = try Rig.create();
    defer live.destroy();
    const asks = [_]c.request.Request{.{ .name = c.parts.panel_name, .at = panel_at, .fault = .{ .garbage = 713 } }};
    live.board.asks.keep(live.arena.allocator(), &asks);
    try ra8.board.plug.all(&live.board);
    live.plugs = Plugs.init(&live.board, live.arena.allocator());
    _ = live.board.spi.channels[1].device.?.exchange(0);
    var saved = try live.save();
    defer saved.deinit();
    const expected = live.board.spi.channels[1].device.?.exchange(0);
    for (0..3) |_| {
        try live.restore(saved.written());
        try std.testing.expectEqual(expected, live.board.spi.channels[1].device.?.exchange(0));
    }
}

test "attachment strict runtime fault on startup panel retains its owned select and frees planes" {
    const live = try Rig.create();
    defer live.destroy();
    const asks = [_]c.request.Request{.{ .name = c.parts.panel_name, .at = panel_at }};
    live.board.asks.keep(live.arena.allocator(), &asks);
    try ra8.board.plug.all(&live.board);
    live.plugs = Plugs.init(&live.board, live.arena.allocator());
    const panel = live.board.asks.attached_eink.?;
    var restored = false;
    defer if (!restored) panel.deinit();
    panel.planes.allocator = std.testing.allocator;
    panel.planes.geometry = .{ .width = 3, .height = 2 };
    try std.testing.expect(panel.planes.ready());
    panel.planes.image.set(2, 1, 0xa5);
    try live.faults.set(panel_at, .{ .garbage = 713 });
    var graph: ra8.session.board.state.attachments.graph.Graph = .{};
    _ = try ra8.session.board.state.attachments.capture(&live.board, live.binding(), &graph);
    for (graph.nodes[0..graph.count]) |node| {
        if (node.kind == .part and node.kind.part == .panel) try std.testing.expectEqualDeep(panel_at, node.at);
    }
    var saved = try live.save();
    defer saved.deinit();
    try live.restore(saved.written());
    restored = true;
    try std.testing.expectEqual(@as(u8, 0xa5), live.board.asks.attached_eink.?.planes.image.pixel(2, 1));
    try live.restore(saved.written());
}
