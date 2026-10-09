//! Covers src/interfaces/gui/devices_panel.zig: the panel unplugs and re-plugs the
//! MAX17048 on i2c:riic@0x36 through a real session over a real board, the
//! event stream records each change, and a refused plug leaves the row as
//! it was (RA8EMU-703).
const std = @import("std");
const ra8 = @import("ra8");

const Board = ra8.board.Board;
const api = ra8.core.session_api;
const session_plug = ra8.board.session_plug;
const devices = ra8.gui.devices_panel;

const gauge_at: devices.Endpoint = .{ .i2c = .{ .line = .riic, .address = 0x36 } };
const modem_at: devices.Endpoint = .{ .uart = .{ .channel = 3 } };

const Rig = struct {
    arena: std.heap.ArenaAllocator,
    board: Board,
    plugs: session_plug.Plugs = undefined,
    session: api.Session = .{ .live = undefined },
    rows: [2]devices.Row = .{
        .{ .at = gauge_at, .part = null },
        .{ .at = modem_at, .part = null },
    },
    subscription: usize = undefined,

    fn setUp(self: *Rig) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.board = Board.init(std.testing.allocator);
        self.plugs = session_plug.Plugs.init(&self.board, self.arena.allocator());
        self.session.attachPlugs(self.plugs.hook());
        self.subscription = try self.session.subscribe();
    }

    fn tearDown(self: *Rig) void {
        self.board.deinit();
        self.arena.deinit();
    }

    fn panel(self: *Rig) devices.Panel {
        return .{ .session = &self.session, .rows = &self.rows };
    }

    fn gaugeAnswers(self: *Rig) bool {
        return self.board.wire.controller.devices.answering(0x36) != null;
    }
};

test "the panel unplugs the gauge and plugs it back through the session" {
    var rig: Rig = .{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    var panel = rig.panel();
    const row = panel.find(gauge_at).?;
    try panel.plug(row, "max17048");
    try std.testing.expect(rig.gaugeAnswers());
    try std.testing.expectEqualStrings("max17048", rig.rows[row].part.?);
    try panel.toggle(row, "max17048");
    try std.testing.expect(!rig.gaugeAnswers());
    try std.testing.expect(rig.rows[row].part == null);
    try panel.toggle(row, "max17048");
    try std.testing.expect(rig.gaugeAnswers());
    var events: [3]api.Event = undefined;
    const got = rig.session.pollEvents(rig.subscription, &events).?;
    try std.testing.expectEqual(@as(usize, 3), got.count);
    try std.testing.expectEqual(api.Event.Kind.plugged, events[0].kind);
    try std.testing.expectEqual(api.Event.Kind.unplugged, events[1].kind);
    try std.testing.expectEqual(api.Event.Kind.plugged, events[2].kind);
}

test "a refused change leaves the row showing what is on the line" {
    var rig: Rig = .{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    var panel = rig.panel();
    try std.testing.expectError(error.UnknownModel, panel.plug(0, "nope"));
    try std.testing.expect(rig.rows[0].part == null);
    try std.testing.expectError(session_plug.Error.NothingFitted, panel.unplug(1));
    try panel.plug(1, "modem");
    try std.testing.expectError(error.ChannelTaken, panel.plug(1, "modem"));
    try std.testing.expectEqualStrings("modem", rig.rows[1].part.?);
    var events: [1]api.Event = undefined;
    try std.testing.expectEqual(@as(usize, 1), rig.session.pollEvents(rig.subscription, &events).?.count);
    try std.testing.expect(panel.find(.{ .uart = .{ .channel = 4 } }) == null);
}

test "a panel over a session with no plug hook refuses without moving a row" {
    var bare: api.Session = .{ .live = undefined };
    var rows = [_]devices.Row{.{ .at = gauge_at, .part = "max17048" }};
    var panel: devices.Panel = .{ .session = &bare, .rows = &rows };
    try std.testing.expectError(api.Error.NoPlugs, panel.toggle(0, "max17048"));
    try std.testing.expectEqualStrings("max17048", rows[0].part.?);
}
