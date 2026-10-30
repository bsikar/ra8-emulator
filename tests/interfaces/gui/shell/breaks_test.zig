//! Host tests for the run-to point on the shell's disassembly leaves
//! (RA8EMU-1171): a click asks set_breakpoint with the line's address, a
//! click on a line that holds one asks clear_breakpoint with its id, a
//! click made while an ask is in flight goes after it answers, and the
//! session's breakpoint_set event adds a mark no click placed.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const proto = ra8.rpc.session.rpc;
const draw_list = ra8.render.draw_list;
const frame = gui_app.shell.frame;
const shell_memory = gui_app.shell.memory;
const shell_breaks = gui_app.shell.breaks;
const shell_panes = gui_app.shell.panes;
const memory_pane = gui_app.memory_pane;
const pane_layout = gui_app.pane_layout;
const disasm_pane = gui_app.disasm_pane;
const Stdio = ra8.rpc.stdio_transport.Stdio;
const session_link = gui_app.session_link;
const Env = proto.Client.Env;

test "a disassembly click marks a live breakpoint, runs to it and clears it" {
    const Live = @import("../live_shell.zig").Live;
    var live: Live = undefined;
    try live.open("tests/fixtures/gpio/blink.elf", 1);
    defer live.deinit();
    var code: shell_memory.Pair = .{ .follows = .pc };
    var breaks: shell_breaks.Breaks = .{};
    var devices: gui_app.shell.devices.Devices = .{};
    live.shell.code = &code;
    live.shell.breaks = &breaks;
    live.shell.devices = &devices;
    live.panes.code = &code;
    live.panes.breaks = &breaks;
    for (0..30) |_| {
        try live.step();
        if (code.cores[0].now != null) break;
    }
    const gpa = std.testing.allocator;
    var solved = try frame.solve(&live.shell.layout, gpa, 640, 480);
    defer solved.deinit(gpa);
    for (solved.panes.items) |placed| {
        const pane = live.shell.layout.pane(placed.index) orelse continue;
        if (pane.kind != .disasm or pane.core != .cpu0) continue;
        const body = frame.bodyOf(placed.area);
        const snapshot = shell_panes.codeSnapshotFrom(code.cores[0].from, &code.cores[0].now.?, frame.toGeom(body));
        const address = snapshot.lines[2].address;
        const band = disasm_pane.rowRect(body, 2);
        try live.clickIn(band);
        for (0..5) |_| try live.step();
        try std.testing.expectEqualSlices(u32, &.{address}, breaks.marks(.cpu0));
        try std.testing.expectEqual(@as(?u32, null), breaks.cores[0].flight);
        try std.testing.expect(breaks.cores[0].ids[0] != 0);
        try live.clickIn(band);
        for (0..5) |_| try live.step();
        try std.testing.expectEqual(@as(usize, 0), breaks.marks(.cpu0).len);
        try live.clickIn(band);
        for (0..5) |_| try live.step();
        const serial = live.registers.cores[0].serial;
        try live.click(.run);
        try live.untilRead(serial);
        try std.testing.expectEqual(address, live.pc());
        return;
    }
    return error.NoDisassemblyPane;
}

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

/// A solved frame whose one leaf is a disassembly pane on cpu0.
const Frame = struct {
    layout: pane_layout.Layout,
    solved: pane_layout.Solved,
    body: draw_list.Rect,

    fn init(gpa: std.mem.Allocator) !Frame {
        var layout = try pane_layout.Layout.init(gpa, .{ .kind = .disasm, .core = .cpu0 });
        errdefer layout.deinit();
        const solved = try frame.solve(&layout, gpa, 480, 320);
        return .{ .layout = layout, .solved = solved, .body = frame.bodyOf(solved.panes.items[0].area) };
    }

    fn deinit(self: *Frame, gpa: std.mem.Allocator) void {
        self.solved.deinit(gpa);
        self.layout.deinit();
    }
};

/// Publish a code read on cpu0: 32 rows of `bx lr` (0x4770) from 0x1000,
/// so every line is two bytes and row `row` sits at 0x1000 + 2 * row.
fn publishCode(pair: *shell_memory.Pair) void {
    var gathered: memory_pane.Snapshot = .{ .base = 0x1000, .count = shell_memory.rows };
    for (0..shell_memory.rows) |row| {
        for (0..memory_pane.per_row / 2) |half| {
            const at = row * memory_pane.per_row + half * 2;
            gathered.bytes[at] = 0x70;
            gathered.bytes[at + 1] = 0x47;
            gathered.readable[at] = true;
            gathered.readable[at + 1] = true;
        }
    }
    pair.cores[0].gathered = gathered;
    pair.cores[0].from = 0x1000;
    pair.cores[0].asked_from = 0x1000;
    pair.cores[0].now = gathered;
}

/// The click point in row `row`'s band of `frame`'s leaf.
fn bandPoint(f: *const Frame, row: usize) draw_list.Rect {
    const band = disasm_pane.rowRect(f.body, row);
    return .{ .x = band.x + @divTrunc(band.w, 2), .y = band.y + @divTrunc(band.h, 2), .w = 0, .h = 0 };
}

test "a click asks set_breakpoint with the line's address" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    const gpa = std.testing.allocator;
    var f = try Frame.init(gpa);
    defer f.deinit(gpa);
    var code: shell_memory.Pair = .{ .follows = .pc };
    publishCode(&code);
    var brks: shell_breaks.Breaks = .{};

    const at = bandPoint(&f, 2);
    try std.testing.expect(brks.clickIn(&wire.link, &code, &f.layout, &f.solved, at.x, at.y));
    const flight = brks.cores[0].flight orelse return error.TestUnexpectedResult;
    var buf: [8]u8 = undefined;
    const placed = try proto.encode(proto.U32, .{ .value = 7 }, &buf);
    brks.observe(.{ .response = .{ .id = flight, .result = .{ .ok = placed } } });
    try std.testing.expectEqual(@as(?u32, null), brks.cores[0].flight);
    try std.testing.expectEqualSlices(u32, &.{0x1004}, brks.marks(.cpu0));
    try std.testing.expectEqual(@as(u32, 7), brks.cores[0].ids[0]);
}

test "a click on a marked line asks clear_breakpoint with its id" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    const gpa = std.testing.allocator;
    var f = try Frame.init(gpa);
    defer f.deinit(gpa);
    var code: shell_memory.Pair = .{ .follows = .pc };
    publishCode(&code);
    var brks: shell_breaks.Breaks = .{};

    const at = bandPoint(&f, 2);
    try std.testing.expect(brks.clickIn(&wire.link, &code, &f.layout, &f.solved, at.x, at.y));
    var buf: [8]u8 = undefined;
    const placed = try proto.encode(proto.U32, .{ .value = 7 }, &buf);
    brks.observe(.{ .response = .{ .id = brks.cores[0].flight orelse return error.TestUnexpectedResult, .result = .{ .ok = placed } } });

    try std.testing.expect(brks.clickIn(&wire.link, &code, &f.layout, &f.solved, at.x, at.y));
    brks.observe(.{ .response = .{ .id = brks.cores[0].flight orelse return error.TestUnexpectedResult, .result = .{ .ok = "" } } });
    try std.testing.expectEqual(@as(usize, 0), brks.marks(.cpu0).len);
}

test "the session's breakpoint_set event adds a mark no click can clear" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    const gpa = std.testing.allocator;
    var f = try Frame.init(gpa);
    defer f.deinit(gpa);
    var code: shell_memory.Pair = .{ .follows = .pc };
    publishCode(&code);
    var brks: shell_breaks.Breaks = .{};

    var buf: [16]u8 = undefined;
    const payload = try proto.encode(proto.SessionEvent, .{ .core = .cpu0, .kind = .breakpoint_set, .address = 0x1008 }, &buf);
    brks.observe(.{ .event = .{ .topic = @backingInt(proto.Topic.session), .payload = payload } });
    try std.testing.expectEqualSlices(u32, &.{0x1008}, brks.marks(.cpu0));

    // A mark with no id on file stays when its line is clicked.
    const at = bandPoint(&f, 4);
    try std.testing.expect(brks.clickIn(&wire.link, &code, &f.layout, &f.solved, at.x, at.y));
    try std.testing.expectEqual(@as(?u32, null), brks.cores[0].flight);
    try std.testing.expectEqualSlices(u32, &.{0x1008}, brks.marks(.cpu0));
}

test "a click made while an ask is in flight goes after it answers" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    const gpa = std.testing.allocator;
    var f = try Frame.init(gpa);
    defer f.deinit(gpa);
    var code: shell_memory.Pair = .{ .follows = .pc };
    publishCode(&code);
    var brks: shell_breaks.Breaks = .{};

    const first = bandPoint(&f, 2);
    try std.testing.expect(brks.clickIn(&wire.link, &code, &f.layout, &f.solved, first.x, first.y));
    const flight = brks.cores[0].flight orelse return error.TestUnexpectedResult;
    const second = bandPoint(&f, 3);
    try std.testing.expect(brks.clickIn(&wire.link, &code, &f.layout, &f.solved, second.x, second.y));
    try std.testing.expectEqual(@as(u32, 0x1006), brks.cores[0].queued.?);

    var buf: [8]u8 = undefined;
    const placed = try proto.encode(proto.U32, .{ .value = 7 }, &buf);
    brks.observe(.{ .response = .{ .id = flight, .result = .{ .ok = placed } } });
    brks.attach(&wire.link);
    const queued = brks.cores[0].flight orelse return error.TestUnexpectedResult;
    try std.testing.expect(queued != flight);
    brks.observe(.{ .response = .{ .id = queued, .result = .{ .ok = placed } } });
    try std.testing.expectEqualSlices(u32, &.{ 0x1004, 0x1006 }, brks.marks(.cpu0));
}

test "a press off the lines is left alone" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    const gpa = std.testing.allocator;
    var f = try Frame.init(gpa);
    defer f.deinit(gpa);
    var code: shell_memory.Pair = .{ .follows = .pc };
    var brks: shell_breaks.Breaks = .{};

    // No read published yet: the pane shows nothing.
    const at = bandPoint(&f, 0);
    try std.testing.expect(!brks.clickIn(&wire.link, &code, &f.layout, &f.solved, at.x, at.y));

    publishCode(&code);
    // Below the last drawn row there is no line to hit.
    const past = disasm_pane.rowRect(f.body, disasm_pane.rows(f.body));
    try std.testing.expect(!brks.clickIn(&wire.link, &code, &f.layout, &f.solved, past.x + @divTrunc(past.w, 2), past.y + @divTrunc(past.h, 2)));
    try std.testing.expect(!brks.clickIn(&wire.link, &code, &f.layout, &f.solved, f.body.x - 1, f.body.y));
    try std.testing.expectEqual(@as(?u32, null), brks.cores[0].flight);
}
