//! Covers the devices pane in src/gui/host_loop.zig: a click on the pane
//! in the shown window unplugs the MAX17048 at i2c:riic@0x36 mid-run and a
//! second click plugs it back, each landing at the engine's park and
//! showing in the session's event stream (RA8EMU-703).
const std = @import("std");
const ra8 = @import("ra8");

const Board = ra8.board.Board;
const api = ra8.core.session_api;
const session_plug = ra8.board.session_plug;
const host_loop = ra8.gui.host_loop;
const board_view = host_loop.board_view;
const devices = ra8.gui.devices_panel;
const pane = ra8.gui.devices_pane;
const plug_post = ra8.gui.plug_post;
const Headless = ra8.gui.headless.Headless;

const gauge_at: devices.Endpoint = .{ .i2c = .{ .line = .riic, .address = 0x36 } };

const Fake = struct {
    panel: [4]u32 = .{ 0, 0, 0, 0 },
    leds: [1]board_view.Led = .{.{ .rgb565 = 0, .on = false }},

    fn run(self: *Fake) host_loop.Run {
        return .{ .ctx = self, .vtable = &.{ .step = step, .board = board, .camera = camera } };
    }

    fn step(_: *anyopaque) bool {
        return true;
    }

    fn board(ctx: *anyopaque) host_loop.Board {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return .{ .panel = &self.panel, .width = 2, .height = 2, .leds = &self.leds };
    }

    fn camera(_: *anyopaque) ?host_loop.Camera {
        return null;
    }
};

const Rig = struct {
    arena: std.heap.ArenaAllocator,
    board: Board,
    plugs: session_plug.Plugs = undefined,
    post: plug_post.PlugPost = .{ .io = std.testing.io },
    session: api.Session = .{ .live = undefined },
    rows: [1]devices.Row = .{.{ .at = gauge_at, .part = null }},
    panel: devices.Panel = undefined,
    subscription: usize = undefined,

    fn setUp(self: *Rig) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.board = Board.init(std.testing.allocator);
        self.plugs = session_plug.Plugs.init(&self.board, self.arena.allocator());
        self.session.attachPlugs(self.post.hook());
        self.panel = .{ .session = &self.session, .rows = &self.rows };
        self.subscription = try self.session.subscribe();
    }

    fn tearDown(self: *Rig) void {
        self.board.deinit();
        self.arena.deinit();
    }

    fn park(self: *Rig) usize {
        return self.post.apply(self.plugs.hook());
    }

    fn gaugeAnswers(self: *Rig) bool {
        return self.board.wire.controller.devices.answering(0x36) != null;
    }
};

fn press(at: ra8.gui.draw_list.Rect) ra8.gui.platform.Event {
    return .{ .button = .{ .button = 1, .down = true, .x = at.x + 2, .y = at.y + 2 } };
}

test "clicking the gauge's row unplugs it mid-run and a second click plugs it back" {
    var rig = Rig{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    try rig.panel.plug(0, "max17048");
    try std.testing.expectEqual(@as(usize, 1), rig.park());
    try std.testing.expect(rig.gaugeAnswers());

    var window = Headless.init(std.testing.allocator, 400, 300);
    defer window.deinit();
    var fake = Fake{};
    var loop = host_loop.Loop{ .allocator = std.testing.allocator };
    defer loop.deinit();
    loop.useDevices(&rig.panel, &rig.post);
    try std.testing.expect(try loop.tick(window.platform(), fake.run()));
    const row = pane.rowRect(loop.devicesArea(.{ .width = 400, .height = 300 }), 0);
    try std.testing.expect(row.h > 0);

    try window.feed(press(row));
    try std.testing.expect(try loop.tick(window.platform(), fake.run()));
    try std.testing.expect(rig.gaugeAnswers());
    try std.testing.expectEqual(@as(usize, 1), rig.park());
    try std.testing.expect(!rig.gaugeAnswers());
    try std.testing.expectEqual(@as(?[]const u8, null), rig.rows[0].part);

    try window.feed(press(row));
    try std.testing.expect(try loop.tick(window.platform(), fake.run()));
    try std.testing.expectEqual(@as(usize, 1), rig.park());
    try std.testing.expect(rig.gaugeAnswers());
    try std.testing.expectEqualStrings("max17048", rig.rows[0].part.?);
    const want = [_]api.Event.Kind{ .plugged, .unplugged, .plugged };
    var events: [want.len]api.Event = undefined;
    const got = rig.session.pollEvents(rig.subscription, &events).?;
    try std.testing.expectEqual(want.len, got.count);
    for (events, want) |event, kind| try std.testing.expectEqual(kind, event.kind);
}

test "a click outside the devices pane changes nothing" {
    var rig = Rig{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    try rig.panel.plug(0, "max17048");
    _ = rig.park();
    var window = Headless.init(std.testing.allocator, 400, 300);
    defer window.deinit();
    var fake = Fake{};
    var loop = host_loop.Loop{ .allocator = std.testing.allocator };
    defer loop.deinit();
    loop.useDevices(&rig.panel, &rig.post);
    try window.feed(press(.{ .x = 0, .y = 0, .w = 4, .h = 4 }));
    try std.testing.expect(try loop.tick(window.platform(), fake.run()));
    try std.testing.expectEqual(@as(usize, 0), rig.park());
    try std.testing.expect(rig.gaugeAnswers());
}
