//! Host tests for the shell's locals leaf (src/interfaces/gui/
//! shell/locals.zig, RA8EMU-805): one ask goes out only once due, its
//! answer becomes the shown rows, a stop of the bound core makes an ask
//! due, a refused ask keeps the last rows with a note, an answer sent
//! before a load is dropped, and a packed list whose count disagrees is
//! refused. The frame choice (RA8EMU-1187): a picked stack frame's ask
//! replaces one in flight, a stop resets the choice, and a click on a
//! stack pane's frame selects it.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const proto = ra8.rpc.session.rpc;
const locals_wire = ra8.rpc.locals_wire;
const shell_locals = gui_app.shell.locals;
const Locals = shell_locals.Locals;
const Stdio = ra8.rpc.stdio_transport.Stdio;
const session_link = gui_app.session_link;
const draw_list = ra8.render.draw_list;
const frame = gui_app.shell.frame;
const shell_stack = gui_app.shell.stack;
const stack_pane = gui_app.stack_pane;
const pane_layout = gui_app.pane_layout;
const Env = proto.Client.Env;

/// A link that has finished its greeting, writing into a pipe nobody answers.
const Wire = struct {
    link: session_link.Link = undefined,
    io: Stdio = .{},
    fds: [4]std.posix.fd_t = undefined,
    rx: [2 * Env.max_frame]u8 = undefined,
    tx: [Env.max_frame]u8 = undefined,

    fn open(self: *Wire) !void {
        const down = try ra8.host.pipe_pair.create(.{});
        const up = try ra8.host.pipe_pair.create(.{});
        self.fds = .{ down[0], down[1], up[0], up[1] };
        self.io = .{ .input = up[0], .output = down[1] };
        self.link.open(self.io.transport(), &self.rx, &self.tx);
        self.link.state = .{ .connected = .{ .version = proto.protocol_version, .caps = proto.capabilities } };
        self.link.client.peer_caps = proto.capabilities;
    }

    fn close(self: *Wire) void {
        for (self.fds) |fd| ra8.host.read.close(fd);
    }
};

const ch_row: proto.LocalRow = .{ .name = "ch", .type_name = "char", .size = 1, .where_kind = 1, .where_a = @bitCast(@as(i64, -8)), .where_b = 0 };
const val_row: proto.LocalRow = .{ .name = "val", .type_name = "u32", .size = 4, .where_kind = 2, .where_a = 4, .where_b = 16 };

/// Answer `id` with `count` and the two rows above packed.
fn answer(model: *Locals, id: u32, count: u8) !void {
    var rows: [proto.locals_bytes]u8 = undefined;
    var at: usize = 0;
    try locals_wire.put(&rows, &at, ch_row);
    try locals_wire.put(&rows, &at, val_row);
    var bytes: [proto.locals_bytes + 16]u8 = undefined;
    const payload = try proto.encode(proto.Locals, .{ .core = model.core, .count = count, .rows = rows[0..at] }, &bytes);
    model.observe(.{ .response = .{ .id = id, .result = .{ .ok = payload } } });
}

fn stop(model: *Locals, core: proto.Core) !void {
    var bytes: [32]u8 = undefined;
    const payload = try proto.encode(proto.Stopped, .{ .core = core, .reason = .stepped, .address = 0x100, .detail = 0 }, &bytes);
    model.observe(.{ .event = .{ .topic = @backingInt(proto.Topic.stop), .payload = payload } });
}

test "an ask goes out only once due, and one at a time" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var model: Locals = .{ .core = .cpu0 };
    model.attach(&wire.link);
    try std.testing.expectEqual(@as(?u32, null), model.asked);
    model.reload();
    model.attach(&wire.link);
    const first = model.asked.?;
    model.want = true;
    model.attach(&wire.link);
    try std.testing.expectEqual(first, model.asked.?);
    try std.testing.expect(model.want);
}

test "the answer becomes the shown rows with names and types copied" {
    var model: Locals = .{ .core = .cpu1, .asked = 7 };
    try std.testing.expectEqualStrings("waiting for the locals", model.note().?);
    try answer(&model, 7, 2);
    try std.testing.expectEqual(@as(?u32, null), model.asked);
    const snap = model.now.?;
    try std.testing.expectEqual(@as(usize, 2), snap.count);
    try std.testing.expectEqualStrings("ch", snap.rows[0].name());
    try std.testing.expectEqualStrings("char", snap.rows[0].type_name());
    try std.testing.expectEqual(@as(u64, 1), snap.rows[0].size);
    try std.testing.expectEqual(@as(u8, 1), snap.rows[0].where_kind);
    try std.testing.expectEqual(@as(i64, -8), snap.rows[0].where_a);
    try std.testing.expectEqualStrings("val", snap.rows[1].name());
    try std.testing.expectEqual(@as(u8, 2), snap.rows[1].where_kind);
    try std.testing.expectEqual(@as(i64, 16), snap.rows[1].where_b);
    try std.testing.expectEqual(@as(?[]const u8, null), model.note());
}

test "a stop of the bound core makes an ask due" {
    var model: Locals = .{ .core = .cpu1 };
    try stop(&model, .cpu0);
    try std.testing.expect(!model.want);
    try stop(&model, .cpu1);
    try std.testing.expect(model.want);
}

test "a refused ask keeps the last rows with a note" {
    var model: Locals = .{ .core = .cpu0, .asked = 3 };
    try answer(&model, 3, 2);
    try std.testing.expectEqual(@as(usize, 2), model.now.?.count);
    // A refusal of an ask in flight keeps the shown rows and sets the note;
    // a response to an id the leaf never asked is ignored.
    model.asked = 7;
    model.observe(.{ .response = .{ .id = 7, .result = .{ .err = @fromBackingInt(@intCast(proto.app_codes.refused)) } } });
    model.observe(.{ .response = .{ .id = 9, .result = .{ .err = @fromBackingInt(@intCast(proto.app_codes.refused)) } } });
    try std.testing.expect(model.refused);
    try std.testing.expectEqual(@as(usize, 2), model.now.?.count);
    try std.testing.expectEqualStrings("the session would not read the locals", model.note().?);
}

test "an answer sent before a load is dropped" {
    var model: Locals = .{ .core = .cpu0, .asked = 5 };
    model.reload();
    try std.testing.expect(model.stale);
    try answer(&model, 5, 2);
    try std.testing.expectEqual(@as(?shell_locals.Snapshot, null), model.now);
    try std.testing.expect(model.want);
    try std.testing.expect(!model.stale);
}

test "a packed list whose count disagrees is refused" {
    var model: Locals = .{ .core = .cpu0, .asked = 11 };
    try answer(&model, 11, 5);
    try std.testing.expect(model.refused);
}

/// A solved frame whose one leaf is a stack pane on cpu0.
const StackFrame = struct {
    layout: pane_layout.Layout,
    solved: pane_layout.Solved,
    body: draw_list.Rect,

    fn init(gpa: std.mem.Allocator) !StackFrame {
        var layout = try pane_layout.Layout.init(gpa, .{ .kind = .stack, .core = .cpu0 });
        errdefer layout.deinit();
        const solved = try frame.solve(&layout, gpa, 480, 320);
        return .{ .layout = layout, .solved = solved, .body = frame.bodyOf(solved.panes.items[0].area) };
    }

    fn deinit(self: *StackFrame, gpa: std.mem.Allocator) void {
        self.solved.deinit(gpa);
        self.layout.deinit();
    }
};

/// Publish a three-frame chain on cpu0, so a click has rows to land on.
fn publishStack(pair: *shell_stack.Pair) void {
    var snap: stack_pane.Snapshot = .{};
    snap.count = 3;
    for (0..3) |i| snap.frames[i].pc = @intCast(0x1000 + i * 4);
    pair.cores[0].now = snap;
}

test "picking a frame re-asks there and drops the old answer" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var model: Locals = .{ .core = .cpu0 };
    model.reload();
    model.attach(&wire.link);
    const first = model.asked.?;
    model.pickFrame(2);
    try std.testing.expectEqual(@as(u32, 2), model.frame);
    try std.testing.expect(model.want);
    // The answer to the first ask describes frame 0: dropped, a fresh
    // ask for the chosen frame goes out.
    try answer(&model, first, 2);
    try std.testing.expectEqual(@as(?shell_locals.Snapshot, null), model.now);
    model.attach(&wire.link);
    try std.testing.expect(model.asked != null and model.asked.? != first);
}

test "a click on the shown frame is a no-op" {
    var model: Locals = .{ .core = .cpu0 };
    model.pickFrame(0);
    try std.testing.expect(!model.want);
}

test "a stop resets the choice to the stopped pc" {
    var model: Locals = .{ .core = .cpu1 };
    model.pickFrame(2);
    try stop(&model, .cpu0);
    try std.testing.expectEqual(@as(u32, 2), model.frame);
    try stop(&model, .cpu1);
    try std.testing.expectEqual(@as(u32, 0), model.frame);
    try std.testing.expect(model.want);
}

test "a click on a stack pane's frame selects it" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    const gpa = std.testing.allocator;
    var f = try StackFrame.init(gpa);
    defer f.deinit(gpa);
    var pair: shell_locals.Pair = .{};
    var chain: shell_stack.Pair = .{};
    publishStack(&chain);

    const band = stack_pane.rowRect(f.body, 2);
    const at = .{ .x = band.x + @divTrunc(band.w, 2), .y = band.y + @divTrunc(band.h, 2), .w = 0, .h = 0 };
    try std.testing.expect(pair.clickIn(&chain, &f.layout, &f.solved, at.x, at.y));
    try std.testing.expectEqual(@as(u32, 2), pair.cores[0].frame);
    try std.testing.expect(pair.cores[0].want);
    // The ask goes out for the chosen frame.
    pair.attach(&wire.link);
    try std.testing.expect(!pair.cores[0].want);
    // A click on the frame already shown is consumed and asks nothing new.
    try std.testing.expect(pair.clickIn(&chain, &f.layout, &f.solved, at.x, at.y));
    try std.testing.expect(!pair.cores[0].want);
}
