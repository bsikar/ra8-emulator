//! Timeline cursor routing through the actual shell painter and mouse events.
const std = @import("std");
const ra8 = @import("ra8");
const gui = @import("gui_app");
const Rig = @import("../local_rig.zig").Rig;
const frame = gui.shell.frame;
const pane = gui.timeline_pane;
const layout = gui.pane_layout;
const Rect = ra8.render.draw_list.Rect;
const Color = ra8.render.draw_list.Color;
const proto = ra8.rpc.session.rpc;
const gpa = std.testing.allocator;
const image = "tests/fixtures/gpio/buttons.elf";

const Bench = struct {
    rig: Rig,
    shell: gui.shell.loop.Shell,
    window: gui.headless.Headless,
    panes: gui.shell.panes.Panes = .{},

    fn open(self: *Bench, shape: layout.Layout, height: u32) !void {
        self.* = .{ .rig = undefined, .shell = undefined, .window = undefined };
        try self.rig.open(image);
        errdefer self.rig.deinit();
        self.shell = gui.shell.loop.Shell.init(gpa, shape);
        errdefer self.shell.deinit();
        self.window = gui.headless.Headless.init(gpa, 480, height);
        self.shell.link = &self.rig.link;
        self.shell.themes.choose(.dark);
        const model = &self.shell.timeline.?;
        try model.take(.{ .when = 100, .core = 0, .kind = .switch_to, .thread = 0xA });
        try model.take(.{ .when = 700, .core = 0, .kind = .switch_to, .thread = 0xB });
        try model.finish(1000);
        self.panes.timeline = model;
        self.shell.painter = self.panes.painter();
        try self.draw();
    }

    fn deinit(self: *Bench) void {
        self.window.deinit();
        self.shell.deinit();
        self.rig.deinit();
    }

    fn draw(self: *Bench) !void {
        try std.testing.expect(try self.shell.step(self.window.platform()));
    }

    fn body(self: *Bench, which: usize) !Rect {
        var solved = try frame.solve(&self.shell.layout, gpa, 480, @intCast(self.window.drawable.height));
        defer solved.deinit(gpa);
        return frame.bodyOf(solved.panes.items[which].area);
    }

    fn pixel(self: *Bench, x: i32, y: i32) Color {
        return self.window.last.?.at(@intCast(x), @intCast(y));
    }

    fn press(self: *Bench, x: i32, y: i32) !void {
        try self.window.feed(.{ .button = .{ .button = 1, .down = true, .x = x, .y = y } });
        try self.draw();
    }

    fn unchanged(self: *Bench, x: i32, y: i32) !void {
        self.shell.snaps.cursor.moveTo(55);
        const before = self.shell.snaps;
        try self.press(x, y);
        try std.testing.expectEqualDeep(before, self.shell.snaps);
    }
};

test "R1 actual painted 314 pixel A slice selects start100 at row relative260" {
    var bench: Bench = undefined;
    try bench.open(try layout.Layout.init(gpa, .{ .kind = .timeline, .core = .cpu0 }), 320);
    defer bench.deinit();
    const body = try bench.body(0);
    try std.testing.expectEqual(@as(i32, 480), body.w);
    const x0 = body.x + pane.col_w;
    const y = body.y + pane.header_h + 2;
    const blue = gui.colors.palettes.dark.hue.blue;
    var painted: i32 = 0;
    while (painted < body.w - pane.col_w and std.meta.eql(blue, bench.pixel(x0 + painted, y))) : (painted += 1) {}
    try std.testing.expectEqual(@as(i32, 314), painted);
    try std.testing.expectEqual(blue, bench.pixel(x0 + 260, y));
    try bench.press(x0 + 260, y);
    try std.testing.expectEqual(@as(?u64, 100), bench.shell.snaps.cursor.at_ns);
    try std.testing.expectEqualStrings("state not kept this far back", bench.shell.snaps.notice.?);
    try std.testing.expect(bench.shell.snaps.step == .none);
    try bench.unchanged(x0 + painted, y);
    try bench.unchanged(x0 + 260, y + pane.row_h);
    try bench.unchanged(x0 + 10, y + pane.row_h - 2);
}

test "R1 unpainted B lane space does not select its later slice" {
    var bench: Bench = undefined;
    try bench.open(try layout.Layout.init(gpa, .{ .kind = .timeline, .core = .cpu0 }), 320);
    defer bench.deinit();
    const body = try bench.body(0);
    const x = body.x + pane.col_w + 260;
    const y = body.y + pane.header_h + pane.row_h + 2;
    try std.testing.expectEqual(gui.colors.palettes.dark.face, bench.pixel(x, y));
    try bench.unchanged(x, y);
}

test "R2 owning timeline bounds exclude right edge outside name header ruler and gaps" {
    var bench: Bench = undefined;
    try bench.open(try layout.Layout.init(gpa, .{ .kind = .timeline, .core = .cpu0 }), 320);
    defer bench.deinit();
    const body = try bench.body(0);
    const x = body.x + pane.col_w + 340;
    const y = body.y + pane.header_h + pane.row_h + 2;
    try std.testing.expectEqual(gui.colors.palettes.dark.hue.blue, bench.pixel(x, y));
    try bench.unchanged(body.x + body.w, y);
    try bench.unchanged(body.x + body.w + 20, y);
    try bench.unchanged(body.x - 1, y);
    try bench.unchanged(body.x + pane.col_w - 1, y);
    try bench.unchanged(x, body.y - 1);
    try bench.unchanged(x, body.y + 2);
    try bench.unchanged(x, body.y + pane.header_h + pane.row_h - 1);
    try bench.unchanged(x, body.y + body.h - pane.ruler_h);
    try bench.unchanged(x, body.y + body.h);
}

test "R2 adjacent Board panel gets its press and schedules its tap without rewind" {
    var shape = try layout.Layout.init(gpa, .{ .kind = .timeline, .core = .cpu0 });
    _ = try shape.split(shape.root, .across, .{ .kind = .board, .core = .cpu0 });
    var bench: Bench = undefined;
    try bench.open(shape, 240);
    defer bench.deinit();
    var board = gui.shell.board.Board.init(gpa);
    defer board.deinit();
    var pointer: gui.shell.board.input.Pointer = .{};
    board.subscribed = true;
    board.width = 64;
    board.height = 64;
    const grey = Color.rgb(72, 72, 72);
    board.pixels = try gpa.alloc(Color, 64 * 64);
    @memset(board.pixels, grey);
    bench.shell.board = &board;
    bench.shell.board_input = &pointer;
    bench.panes.board = &board;
    bench.panes.board_input = &pointer;
    try bench.draw();
    const left = try bench.body(0);
    const right = try bench.body(1);
    const shown = gui.board.touch.shownIn(gui.board_pane.Layout.of(right, board.parts), board.width, board.height);
    const x = shown.x + @divTrunc(shown.w, 2);
    const y = left.y + pane.header_h + pane.row_h + 2;
    try std.testing.expect(shown.contains(x, y));
    try std.testing.expectEqual(grey, bench.pixel(x, y));
    _ = try bench.rig.link.send(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .session });
    try bench.rig.answer();
    try bench.shell.pump();
    bench.shell.snaps.cursor.moveTo(55);
    const before = bench.shell.snaps;
    try bench.press(x, y);
    try std.testing.expectEqualDeep(before, bench.shell.snaps);
    try std.testing.expectEqual(@as(?Rect, right), pointer.grabbed);
    try std.testing.expect(pointer.drag.start != null);
    try bench.window.feed(.{ .button = .{ .button = 1, .down = false, .x = x, .y = y } });
    try bench.draw();
    try bench.rig.answer();
    var scheduled: usize = 0;
    while (bench.rig.link.pump()) |arrival| switch (arrival) {
        .event => |event| if (event.topic == @backingInt(proto.Topic.session)) {
            const change = try proto.decode(proto.SessionEvent, event.payload);
            if (change.kind == .input_scheduled) scheduled += 1;
        },
        .response => {},
    };
    try std.testing.expectEqual(@as(usize, 1), scheduled);
    try std.testing.expectEqual(@as(?Rect, null), pointer.grabbed);
}

test "R3 a second visible vertically split timeline receives its painted slice click" {
    var shape = try layout.Layout.init(gpa, .{ .kind = .timeline, .core = .cpu0 });
    _ = try shape.split(shape.root, .down, .{ .kind = .timeline, .core = .cpu0 });
    var bench: Bench = undefined;
    try bench.open(shape, 480);
    defer bench.deinit();
    const body = try bench.body(1);
    const x = body.x + pane.col_w + 260;
    const y = body.y + pane.header_h + 2;
    try std.testing.expectEqual(gui.colors.palettes.dark.hue.blue, bench.pixel(x, y));
    try bench.press(x, y);
    try std.testing.expectEqual(@as(?u64, 100), bench.shell.snaps.cursor.at_ns);
}

test "R3 inactive deck timeline does not paint or intercept body clicks" {
    var shape = try layout.Layout.init(gpa, .{ .kind = .empty, .core = .cpu0 });
    const active = try shape.add(.{ .body = .{ .leaf = .{ .kind = .empty, .core = .cpu0 } } });
    const hidden = try shape.add(.{ .body = .{ .leaf = .{ .kind = .timeline, .core = .cpu0 } } });
    try shape.deck(shape.root, &.{ active, hidden });
    var bench: Bench = undefined;
    try bench.open(shape, 320);
    defer bench.deinit();
    const body = try bench.body(0);
    const x = body.x + pane.col_w + 260;
    const y = body.y + pane.header_h + 2;
    try std.testing.expect(!std.meta.eql(gui.colors.palettes.dark.hue.blue, bench.pixel(x, y)));
    try bench.unchanged(x, y);
}
