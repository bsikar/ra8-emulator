//! Covers src/gui/devices_pane.zig: endpoints are labelled the way
//! endpoint.parse reads them, rows that fit are drawn, and a click on the
//! gauge row unplugs it and a second click plugs it back through a real
//! session, with the event stream recording both (RA8EMU-703).
const std = @import("std");
const ra8 = @import("ra8");

const Board = ra8.board.Board;
const api = ra8.core.session_api;
const session_plug = ra8.board.session_plug;
const devices = ra8.gui.devices_panel;
const pane = ra8.gui.devices_pane;
const draw_list = ra8.gui.draw_list;
const endpoint = ra8.periph.registry.model.endpoint;

const gauge_at: devices.Endpoint = .{ .i2c = .{ .line = .riic, .address = 0x36 } };
const area = draw_list.Rect{ .x = 10, .y = 20, .w = 200, .h = 2 * pane.pad + 2 * pane.row_h };

fn glyphs(list: *const draw_list.DrawList) usize {
    var count: usize = 0;
    for (list.commands.items) |command| {
        if (command.shape == .glyph) count += 1;
    }
    return count;
}

const Rig = struct {
    arena: std.heap.ArenaAllocator,
    board: Board,
    plugs: session_plug.Plugs = undefined,
    session: api.Session = .{ .live = undefined },
    rows: [1]devices.Row = .{.{ .at = gauge_at, .part = null }},
    events: [8]api.Event.Kind = undefined,
    seen: usize = 0,

    fn setUp(self: *Rig) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.board = Board.init(std.testing.allocator);
        self.plugs = session_plug.Plugs.init(&self.board, self.arena.allocator());
        self.session.attachPlugs(self.plugs.hook());
        _ = try self.session.subscribe(.{ .context = self, .receive = receive });
    }

    fn tearDown(self: *Rig) void {
        self.board.deinit();
        self.arena.deinit();
    }

    fn receive(context: *anyopaque, event: api.Event) void {
        const self: *Rig = @ptrCast(@alignCast(context));
        if (self.seen < self.events.len) self.events[self.seen] = event.kind;
        self.seen += 1;
    }

    fn gaugeAnswers(self: *Rig) bool {
        return self.board.wire.controller.devices.answering(0x36) != null;
    }
};

test "labels read back as the same endpoint" {
    const cases = [_]devices.Endpoint{
        gauge_at,
        .{ .i2c = .{ .line = .touch, .address = 0x36 } },
        .{ .spi = .{ .channel = 1, .select = 0 } },
        .{ .uart = .{ .channel = 3 } },
        .{ .gpio = .{ .port = 0xA, .pin = 6 } },
    };
    var buffer: [24]u8 = undefined;
    try std.testing.expectEqualStrings("i2c:riic@0x36", pane.label(&buffer, gauge_at));
    for (cases) |at| {
        const back = try endpoint.parse(pane.label(&buffer, at));
        try std.testing.expect(std.meta.eql(at, back));
    }
}

test "rows that fit are drawn, and too short an area draws nothing" {
    var rig: Rig = .{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    const panel: devices.Panel = .{ .session = &rig.session, .rows = &rig.rows };
    var list = draw_list.DrawList.init(std.testing.allocator, 400, 200);
    defer list.deinit();
    try pane.draw(&list, area, panel);
    // "i2c:riic@0x36" has 13 glyphs, then "empty".
    try std.testing.expectEqual(@as(usize, 13 + 5), glyphs(&list));
    list.clear();
    try pane.draw(&list, .{ .x = 0, .y = 0, .w = 200, .h = pane.row_h }, panel);
    try std.testing.expectEqual(@as(usize, 0), list.commands.items.len);
}

test "clicking the gauge row unplugs it and clicking again plugs it back" {
    var rig: Rig = .{ .arena = undefined, .board = undefined };
    try rig.setUp();
    defer rig.tearDown();
    var panel: devices.Panel = .{ .session = &rig.session, .rows = &rig.rows };
    const strip = pane.rowRect(area, 0);
    // A row that never held a part takes the click and does nothing.
    try std.testing.expect(try pane.click(&panel, area, strip.x + 1, strip.y + 1));
    try std.testing.expectEqual(@as(usize, 0), rig.seen);
    try panel.plug(0, "max17048");
    try std.testing.expect(!try pane.click(&panel, area, area.x - 5, strip.y));
    try std.testing.expect(try pane.click(&panel, area, strip.x + 1, strip.y + 1));
    try std.testing.expect(!rig.gaugeAnswers());
    try std.testing.expectEqualStrings("max17048", rig.rows[0].last.?);
    try std.testing.expect(try pane.click(&panel, area, strip.x + 20, strip.y + 3));
    try std.testing.expect(rig.gaugeAnswers());
    try std.testing.expectEqual(@as(usize, 3), rig.seen);
    try std.testing.expectEqual(api.Event.Kind.unplugged, rig.events[1]);
    try std.testing.expectEqual(api.Event.Kind.plugged, rig.events[2]);
}
