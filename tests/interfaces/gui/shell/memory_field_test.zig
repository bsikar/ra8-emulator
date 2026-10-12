//! Host tests for the memory leaf's address field (RA8EMU-934): a hex
//! address or a symbol pins the leaf there and its rows re-read from that
//! row, an empty field returns the leaf to its bound register, a name
//! nothing resolves keeps the text and leaves a note, and the field draws
//! at the foot of the leaf under the rows, with a too-short leaf keeping
//! its rows whole.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const proto = ra8.rpc.session.rpc;
const draw_list = ra8.render.draw_list;
const platform = gui_app.platform;
const shell_memory_field = gui_app.shell.memory_field;
const shell_memory = gui_app.shell.memory;
const shell_registers = gui_app.shell.registers;
const registers_capture = gui_app.registers_capture;
const symbols = ra8.session.symbols;
const Stdio = ra8.rpc.stdio_transport.Stdio;
const session_link = gui_app.session_link;
const Env = proto.Client.Env;

const image_bytes = @embedFile("../../../fixtures/sections/fault_crashlog_hil.elf");
const image: shell_memory_field.Image = shell_memory_field.Image.init(image_bytes) catch unreachable;

const body: draw_list.Rect = .{ .x = 0, .y = 0, .w = 300, .h = 240 };
const rows = shell_memory.rows;

/// A link that has finished its greeting, writing into a pipe nobody answers.
const Wire = struct {
    link: session_link.Link = undefined,
    io: Stdio = .{},
    fds: [4]std.posix.fd_t = undefined,
    rx: [2 * Env.max_frame]u8 = undefined,
    tx: [Env.max_frame]u8 = undefined,

    fn open(self: *Wire) !void {
        const down = try ra8.host.pipe_pair.create(.{});
        errdefer for (down) |fd| ra8.host.read.close(fd);
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

/// A registers pair whose `core` has published a batch with `which` at
/// `value`.
fn published(core: usize, which: shell_registers.Register, value: u32) shell_registers.Pair {
    var pair: shell_registers.Pair = .{};
    var snapshot: shell_registers.Snapshot = .{};
    for (registers_capture.shown, 0..) |shown, index| {
        if (shown == which) snapshot.values[index] = value;
    }
    pair.cores[core].now = snapshot;
    pair.cores[core].serial = 1;
    return pair;
}

/// A pin drawn once in `body` so its field has a press rect, focused, with
/// `text` typed into it (one text event holds at most 8 bytes).
fn typed(pin: *shell_memory_field.Pin, list: *draw_list.DrawList, snapshot: *const shell_memory.Snapshot, text: []const u8) !void {
    try pin.init();
    pin.image = image;
    var target = ra8.render.widget_paint.Target{ .list = list };
    const paint = target.paint();
    try shell_memory_field.draw(&paint, dark, body, snapshot, pin);
    const field = shell_memory_field.fieldRect(body);
    try std.testing.expect(pin.press(field.x + 2, field.y + 2));
    var left = text;
    while (left.len > 0) {
        const take = @min(left.len, 8);
        try std.testing.expect(pin.handle(.{ .text = platform.Text.of(left[0..take]) }));
        left = left[take..];
    }
}

fn enter(pin: *shell_memory_field.Pin) void {
    _ = pin.handle(.{ .key = .{ .code = 0x0D, .down = true } });
}

test "parse takes a hex address with or without 0x, or a symbol, and nothing else" {
    try std.testing.expectEqual(@as(?u32, 0x2200_0100), shell_memory_field.parse("0x22000100", null));
    try std.testing.expectEqual(@as(?u32, 0x2200_0100), shell_memory_field.parse("22000100", null));
    try std.testing.expectEqual(@as(?u32, null), shell_memory_field.parse("", null));
    try std.testing.expectEqual(@as(?u32, null), shell_memory_field.parse("main", null));
    try std.testing.expectEqual(@as(?u32, 0x0200_048D), shell_memory_field.parse("main", image));
    try std.testing.expectEqual(@as(?u32, null), shell_memory_field.parse("nonesuch", image));
}

test "a typed address pins the leaf and its rows re-read from it" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var list = draw_list.DrawList.init(std.testing.allocator, body.w, body.h);
    defer list.deinit();
    const snapshot: shell_memory.Snapshot = .{ .base = 0x2200_0000, .count = rows };
    var pin: shell_memory_field.Pin = .{};
    try typed(&pin, &list, &snapshot, "0x20000123");
    var memory: shell_memory.Pair = .{};
    enter(&pin);
    try std.testing.expect(pin.submit(&memory));
    try std.testing.expectEqual(@as(?u32, 0x2000_0123), memory.pin);
    try std.testing.expect(memory.cores[0].want);
    memory.attach(&wire.link);
    try std.testing.expectEqual(@as(u32, 0x2000_0120), memory.cores[0].gathered.base);
    try std.testing.expectEqual(@as(u32, 0x2000_0130), memory.cores[0].gathered.rowAddress(1));
}

test "an empty field returns the leaf to its bound register" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var list = draw_list.DrawList.init(std.testing.allocator, body.w, body.h);
    defer list.deinit();
    const snapshot: shell_memory.Snapshot = .{ .base = 0x2200_0000, .count = rows };
    var pin: shell_memory_field.Pin = .{};
    try typed(&pin, &list, &snapshot, "22000100");
    var memory: shell_memory.Pair = .{};
    enter(&pin);
    _ = pin.submit(&memory);
    try std.testing.expectEqual(@as(?u32, 0x2200_0100), memory.pin);
    pin.field.clear();
    enter(&pin);
    try std.testing.expect(pin.submit(&memory));
    try std.testing.expectEqual(@as(?u32, null), memory.pin);
    const registers = published(0, .sp, 0x2000_1F3C);
    memory.follow(&registers);
    try std.testing.expect(memory.cores[0].want);
    try std.testing.expectEqual(@as(u32, 0x2000_1F3C), memory.cores[0].address);
}

test "a name nothing resolves keeps the text and leaves a note" {
    var list = draw_list.DrawList.init(std.testing.allocator, body.w, body.h);
    defer list.deinit();
    const snapshot: shell_memory.Snapshot = .{ .base = 0x2200_0000, .count = rows };
    var pin: shell_memory_field.Pin = .{};
    try typed(&pin, &list, &snapshot, "nonesuch");
    pin.image = image;
    var memory: shell_memory.Pair = .{};
    enter(&pin);
    try std.testing.expect(pin.submit(&memory));
    try std.testing.expect(pin.refused);
    try std.testing.expectEqual(@as(?u32, null), memory.pin);
    try std.testing.expectEqualStrings("nonesuch", pin.field.value());
}

test "a leaf too short for the field keeps its rows whole and takes no press" {
    var list = draw_list.DrawList.init(std.testing.allocator, body.w, 24);
    defer list.deinit();
    const snapshot: shell_memory.Snapshot = .{ .base = 0x2200_0000, .count = rows };
    var pin: shell_memory_field.Pin = .{};
    try pin.init();
    var target = ra8.render.widget_paint.Target{ .list = &list };
    const paint = target.paint();
    try shell_memory_field.draw(&paint, dark, .{ .x = 0, .y = 0, .w = body.w, .h = 24 }, &snapshot, &pin);
    try std.testing.expect(!pin.press(4, 4));
}
