//! Host tests for the shell's source leaf (src/interfaces/gui/shell/
//! source.zig, RA8EMU-1125): one source-line ask only once due, its
//! answer's file becomes the shown rows with the pc's line current, a
//! found=0 answer shows no line, a stop of the bound core makes an ask
//! due, a refused ask keeps the last lines with a note, and an answer
//! sent before a load is dropped.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const proto = ra8.rpc.session.rpc;
const shell_source = gui_app.shell.source;
const source_pane = gui_app.source_pane;
const Source = shell_source.Source;
const Stdio = ra8.rpc.stdio_transport.Stdio;
const session_link = gui_app.session_link;
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

const test_path = "ra8_source_leaf_test_rows.c";

/// A small source file the answer can name: three short rows.
fn writeRows() !void {
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = test_path, .data = "int main(void) {\n    return 0;\n}\n" });
}

fn dropRows() void {
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_path) catch {};
}

/// Answer `id` with `place`'s file and line packed.
fn answer(model: *Source, id: u32, found: u8, pc: u32, line: u32, path: []const u8) !void {
    var bytes: [proto.max_payload]u8 = undefined;
    const payload = try proto.encode(proto.SourceLine, .{ .found = found, .pc = pc, .line = line, .path = path }, &bytes);
    model.observe(.{ .response = .{ .id = id, .result = .{ .ok = payload } } });
}

fn stop(model: *Source, core: proto.Core) !void {
    var bytes: [32]u8 = undefined;
    const payload = try proto.encode(proto.Stopped, .{ .core = core, .reason = .stepped, .address = 0x100, .detail = 0 }, &bytes);
    model.observe(.{ .event = .{ .topic = @backingInt(proto.Topic.stop), .payload = payload } });
}

test "an ask goes out only once due, and one at a time" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var pair = shell_source.Pair.init(std.testing.io);
    pair.of(.cpu0).want = true;
    const model: *Source = pair.of(.cpu0);
    model.attach(&wire.link);
    const first = model.asked.?;
    model.want = true;
    model.attach(&wire.link);
    try std.testing.expectEqual(first, model.asked.?);
    try std.testing.expect(model.want);
}

test "the answer's file becomes the shown rows with the pc's line current" {
    try writeRows();
    defer dropRows();
    var model: Source = .{ .core = .cpu0, .io = std.testing.io, .asked = 7 };
    try answer(&model, 7, 1, 0x0200_0100, 2, test_path);
    const shown = model.now.?;
    try std.testing.expectEqual(source_pane.State.shown, shown.state);
    try std.testing.expectEqual(@as(u32, 0x0200_0100), shown.pc);
    try std.testing.expectEqual(@as(u32, 2), shown.current);
    try std.testing.expect(std.mem.endsWith(u8, shown.path(), test_path));
    try std.testing.expectEqual(@as(usize, 3), shown.count);
    try std.testing.expectEqualStrings("    return 0;", shown.rows[1].text());
    try std.testing.expectEqual(model.note(), null);
}

test "a found=0 answer shows no line" {
    var model: Source = .{ .core = .cpu1, .io = std.testing.io, .asked = 3 };
    try answer(&model, 3, 0, 0x0200_0040, 0, "");
    try std.testing.expectEqual(source_pane.State.no_line, model.now.?.state);
    try std.testing.expectEqual(@as(u32, 0x0200_0040), model.now.?.pc);
    try std.testing.expectEqual(model.note(), null);
}

test "a stop of the bound core makes an ask due, a refused ask keeps the note" {
    var wire: Wire = .{};
    try wire.open();
    defer wire.close();
    var model: Source = .{ .core = .cpu0, .io = std.testing.io };
    try stop(&model, .cpu1);
    try std.testing.expect(!model.want);
    try stop(&model, .cpu0);
    try std.testing.expect(model.want);
    // A refused answer keeps the last lines and raises the note.
    var model_held: Source = .{ .core = .cpu0, .io = std.testing.io, .asked = 9 };
    try writeRows();
    defer dropRows();
    try answer(&model_held, 9, 1, 0x100, 1, test_path);
    model_held.asked = 10;
    model_held.observe(.{ .response = .{ .id = 10, .result = .{ .err = .failed } } });
    try std.testing.expect(model_held.refused);
    try std.testing.expect(model_held.now != null);
    try std.testing.expectEqualStrings("the session would not name the source place", model_held.note().?);
}

test "an answer sent before a load is dropped" {
    var model: Source = .{ .core = .cpu0, .io = std.testing.io, .asked = 5 };
    try writeRows();
    defer dropRows();
    model.reload();
    try std.testing.expect(model.stale);
    try std.testing.expectEqual(@as(?shell_source.Snapshot, null), model.now);
    try answer(&model, 5, 1, 0x100, 1, test_path);
    try std.testing.expectEqual(@as(?shell_source.Snapshot, null), model.now);
    try std.testing.expect(!model.stale);
}
