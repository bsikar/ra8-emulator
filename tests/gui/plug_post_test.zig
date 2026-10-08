//! Covers src/gui/plug_post.zig: a panel over a session whose plug hook is
//! the post queues the gauge's unplug and plug without touching the board,
//! the engine's park applies them through the board's own hook, and a
//! change the board refuses comes back for the panel to undo (RA8EMU-703).
const std = @import("std");
const ra8 = @import("ra8");

const Board = ra8.board.Board;
const api = ra8.core.session_api;
const session_plug = ra8.board.session_plug;
const devices = ra8.gui.devices_panel;
const plug_post = ra8.gui.plug_post;

const gauge_at: devices.Endpoint = .{ .i2c = .{ .line = .riic, .address = 0x36 } };
const modem_at: devices.Endpoint = .{ .uart = .{ .channel = 3 } };

const Rig = struct {
    arena: std.heap.ArenaAllocator,
    board: Board,
    plugs: session_plug.Plugs = undefined,
    post: plug_post.PlugPost = .{ .io = std.testing.io },
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
        self.session.attachPlugs(self.post.hook());
        self.subscription = try self.session.subscribe();
    }

    fn tearDown(self: *Rig) void {
        self.board.deinit();
        self.arena.deinit();
    }

    fn panel(self: *Rig) devices.Panel {
        return .{ .session = &self.session, .rows = &self.rows };
    }

    fn park(self: *Rig) usize {
        return self.post.apply(self.plugs.hook());
    }

    fn gaugeAnswers(self: *Rig) bool {
        return self.board.wire.controller.devices.answering(0x36) != null;
    }
};

test "changes wait for the engine's park, then land in order" {
    var rig: Rig = .{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    var panel = rig.panel();
    try panel.plug(0, "max17048");
    try std.testing.expect(!rig.gaugeAnswers());
    try std.testing.expectEqual(@as(usize, 1), rig.park());
    try std.testing.expect(rig.gaugeAnswers());
    try panel.click(0);
    try panel.click(0);
    try std.testing.expect(rig.gaugeAnswers());
    try std.testing.expectEqual(@as(usize, 2), rig.park());
    try std.testing.expect(rig.gaugeAnswers());
    try panel.click(0);
    try std.testing.expectEqual(@as(usize, 1), rig.park());
    try std.testing.expect(!rig.gaugeAnswers());
    var events: [4]api.Event = undefined;
    try std.testing.expectEqual(@as(usize, 4), rig.session.pollEvents(rig.subscription, &events).?.count);
    try std.testing.expectEqual(@as(usize, 0), rig.park());
}

test "a refused change comes back and the panel puts its row back" {
    var rig: Rig = .{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    var panel = rig.panel();
    try panel.plug(1, "nope");
    rig.rows[0] = .{ .at = gauge_at, .part = "max17048" };
    try panel.unplug(0);
    try std.testing.expectEqual(@as(usize, 0), rig.park());
    var out: [plug_post.limits.pending]plug_post.Request = undefined;
    const refused = rig.post.takeRefused(&out);
    try std.testing.expectEqual(@as(usize, 2), refused.len);
    for (refused) |request| panel.refused(request.at, request.name);
    try std.testing.expect(rig.rows[1].part == null);
    try std.testing.expectEqualStrings("max17048", rig.rows[0].part.?);
    try std.testing.expectEqual(@as(usize, 0), rig.post.takeRefused(&out).len);
}

test "a full queue refuses the next change and leaves its row alone" {
    var rig: Rig = .{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    var panel = rig.panel();
    for (0..plug_post.limits.pending / 2) |_| {
        try panel.plug(0, "max17048");
        try panel.unplug(0);
    }
    try std.testing.expectError(plug_post.Error.QueueFull, panel.plug(0, "max17048"));
    try std.testing.expect(rig.rows[0].part == null);
    try std.testing.expectEqual(plug_post.limits.pending, rig.park());
    try std.testing.expect(!rig.gaugeAnswers());
}
