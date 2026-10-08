//! Host tests for register edits from the shell's registers leaves
//! (RA8EMU-946): a q lane writes the S register it aliases, a press lands
//! only on a drawn value, Enter sends one write and Escape none, an
//! accepted write makes the leaf read again, and a refused one keeps the
//! old value with the note drawn under the values.
const std = @import("std");
const ra8 = @import("ra8");
const proto = ra8.interfaces.rpc.session;
const draw_list = ra8.gui.draw_list;
const raster = ra8.gui.raster;
const font = ra8.gui.font;
const pane_layout = ra8.gui.pane_layout;
const frame = ra8.gui.shell_frame;
const panes = ra8.gui.shell_panes;
const status_bar = ra8.gui.status_bar;
const platform = ra8.gui.platform;
const hex_entry = ra8.gui.hex_entry;
const registers_pane = ra8.gui.registers_pane;
const shell_registers = ra8.gui.shell_registers;
const edit = ra8.gui.shell_register_edit;
const Stdio = ra8.interfaces.rpc.stdio.Stdio;
const session_link = ra8.gui.session_link;
const Env = proto.Client.Env;

const shown = registers_pane.shown;
const area: draw_list.Rect = .{ .x = 0, .y = 0, .w = 1200, .h = 600 };

/// A link that has finished its greeting, writing into a pipe nobody answers.
const Wire = struct {
    link: session_link.Link = undefined,
    io: Stdio = .{},
    fds: [4]std.posix.fd_t = undefined,
    rx: [2 * Env.max_frame]u8 = undefined,
    tx: [Env.max_frame]u8 = undefined,

    fn open(self: *Wire) !void {
        const down = try std.Io.Threaded.pipe2(.{});
        const up = try std.Io.Threaded.pipe2(.{});
        self.fds = .{ down[0], down[1], up[0], up[1] };
        self.io = .{ .input = up[0], .output = down[1] };
        self.link.open(self.io.transport(), &self.rx, &self.tx);
        self.link.state = .{ .connected = .{ .version = proto.protocol_version, .caps = proto.capabilities } };
        self.link.client.peer_caps = proto.capabilities;
    }

    fn close(self: *Wire) void {
        for (self.fds) |fd| std.Io.Threaded.closeFd(fd);
    }
};

fn cellOf(which: shell_registers.Register) usize {
    return std.mem.indexOfScalar(shell_registers.Register, &shown, which).?;
}

fn key(code: u32) platform.Event {
    return .{ .key = .{ .code = code, .down = true } };
}

/// Type `digits` into an editor opened on `which` of cpu0 and press Enter.
fn write(editor: *edit.Editor, link: *session_link.Link, which: shell_registers.Register, digits: []const u8) void {
    editor.open = .{ .core = .cpu0, .cell = cellOf(which) };
    _ = editor.handle(link, .{ .text = platform.Text.of(digits) });
    _ = editor.handle(link, key(hex_entry.codes.enter));
}

test "a q lane writes the S register it aliases, a shown cell its own register" {
    try std.testing.expectEqual(proto.Register.msplim, edit.registerOf(cellOf(.msplim)));
    try std.testing.expectEqual(proto.Register.vpr, edit.registerOf(cellOf(.vpr)));
    // Lane k of qN is S[4N+k]: q1[2] is S6.
    try std.testing.expectEqual(proto.Register.s6, edit.registerOf(shown.len + 6));
    try std.testing.expectEqual(proto.Register.s31, edit.registerOf(registers_pane.cells - 1));
}

test "a press lands on a drawn value, never a folded group or a missing MVE group" {
    const cell = cellOf(.s3);
    const rect = registers_pane.cellRect(area, registers_pane.open, cell).?;
    const at = registers_pane.valueOrigin(rect);
    try std.testing.expectEqual(@as(?usize, cell), edit.cellAt(area, registers_pane.open, true, at.x + 1, at.y + 1));
    try std.testing.expectEqual(@as(?usize, null), edit.cellAt(area, registers_pane.open, true, rect.x + 1, at.y + 1));
    var fold = registers_pane.open;
    fold[2] = true;
    const moved = registers_pane.cellRect(area, fold, cell);
    try std.testing.expect(moved == null);

    const lane = shown.len + 6;
    const lane_rect = registers_pane.cellRect(area, registers_pane.open, lane).?;
    const lane_at = registers_pane.valueOrigin(lane_rect);
    try std.testing.expectEqual(@as(?usize, lane), edit.cellAt(area, registers_pane.open, true, lane_at.x + 1, lane_at.y + 1));
    try std.testing.expectEqual(@as(?usize, null), edit.cellAt(area, registers_pane.open, false, lane_at.x + 1, lane_at.y + 1));
}

test "Enter sends one write, Escape closes the field and sends none" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var editor: edit.Editor = .{};
    editor.open = .{ .core = .cpu0, .cell = cellOf(.r0) };
    try std.testing.expect(editor.handle(&wire.link, .{ .text = platform.Text.of("12") }));
    try std.testing.expect(editor.handle(&wire.link, key(hex_entry.codes.escape)));
    try std.testing.expect(editor.open == null and editor.asked == null);
    try std.testing.expect(!editor.handle(&wire.link, key(hex_entry.codes.enter)));

    write(&editor, &wire.link, .msplim, "20000100");
    try std.testing.expect(editor.open == null);
    try std.testing.expect(editor.asked != null);
}

test "an accepted write makes the leaf read again and shows no note" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var pair: shell_registers.Pair = .{};
    pair.cores[0].now = .{};
    var editor: edit.Editor = .{};
    write(&editor, &wire.link, .s3, "40490FDB");
    const id = editor.asked.?.id;
    try std.testing.expect(!editor.observe(&pair, .{ .response = .{ .id = id +% 1, .result = .{ .ok = &.{} } } }));
    try std.testing.expect(editor.observe(&pair, .{ .response = .{ .id = id, .result = .{ .ok = &.{} } } }));
    try std.testing.expect(pair.cores[0].want);
    try std.testing.expect(!pair.cores[1].want);
    try std.testing.expectEqual(@as(?[]const u8, null), editor.note(.cpu0));
}

test "a refused write keeps the old value and draws the note under the values" {
    const gpa = std.testing.allocator;
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var pair: shell_registers.Pair = .{};
    pair.cores[0].now = .{};
    pair.cores[0].now.?.values[cellOf(.msplim)] = 0x2000_0000;
    var editor: edit.Editor = .{};
    write(&editor, &wire.link, .msplim, "20000100");
    const refused: Env.Result = .{ .err = @fromBackingInt(@intCast(0x0100)) };
    try std.testing.expect(editor.observe(&pair, .{ .response = .{ .id = editor.asked.?.id, .result = refused } }));
    try std.testing.expect(!pair.cores[0].want);
    try std.testing.expectEqual(@as(?u32, 0x2000_0000), pair.cores[0].value(.msplim));
    try std.testing.expectEqualStrings(edit.refused_note, editor.note(.cpu0).?);
    try std.testing.expectEqual(@as(?[]const u8, null), editor.note(.cpu1));

    var layout = try pane_layout.twoCore(gpa);
    defer layout.deinit();
    for (layout.nodes.items, 0..) |node, index| if (node.body == .leaf) {
        try layout.setKind(@intCast(index), .registers);
    };
    var solved = try frame.solve(&layout, gpa, 480, 320);
    defer solved.deinit(gpa);
    var list = draw_list.DrawList.init(gpa, 480, 320);
    defer list.deinit();
    const status: status_bar.Status = .{};
    var painter: panes.Panes = .{ .registers = &pair, .edit = &editor };
    try frame.draw(&list, .{ .layout = &layout, .solved = &solved, .status = &status, .state = .closed, .width = 480, .height = 320, .painter = painter.painter() });
    var pixels = try raster.Framebuffer.init(gpa, 480, 320);
    defer pixels.deinit(gpa);
    raster.draw(&pixels, &list, font.atlas);
    for (solved.panes.items) |leaf| {
        const placed = layout.pane(leaf.index) orelse continue;
        const body = frame.bodyOf(leaf.area);
        const band: draw_list.Rect = .{ .x = body.x, .y = body.y + body.h - registers_pane.row_h, .w = body.w, .h = registers_pane.row_h };
        try std.testing.expectEqual(placed.core == .cpu0, holds(&pixels, band, registers_pane.muted));
    }
    // A press that misses every value keeps the note until a write is opened.
    try std.testing.expect(!editor.press(&pair, &layout, &solved, 0, 0));
    try std.testing.expectEqualStrings(edit.refused_note, editor.note(.cpu0).?);
}

fn holds(pixels: *const raster.Framebuffer, rect: draw_list.Rect, color: draw_list.Color) bool {
    var y = rect.y;
    while (y < rect.y + rect.h) : (y += 1) {
        var x = rect.x;
        while (x < rect.x + rect.w) : (x += 1) {
            if (std.meta.eql(pixels.at(@intCast(x), @intCast(y)), color)) return true;
        }
    }
    return false;
}
