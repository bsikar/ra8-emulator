const std = @import("std");
const host = @import("ra8").host;
const probe = @import("cli_app").probe_ctl;

test "probe ctl parses capability and hardware actions" {
    const capabilities = [_][]const u8{ "ra8_emulator", "ctl", "probe", "star", "2331", "capabilities" };
    const registers = [_][]const u8{ "ra8_emulator", "ctl", "probe", "star", "2331", "registers" };
    const halt = [_][]const u8{ "ra8_emulator", "ctl", "probe", "star", "2331", "halt" };
    const resume_args = [_][]const u8{ "ra8_emulator", "ctl", "probe", "star", "2331", "resume" };
    const step_args = [_][]const u8{ "ra8_emulator", "ctl", "probe", "star", "2331", "step" };
    try std.testing.expectEqual(probe.Action.capabilities, (try probe.parse(&capabilities)).action);
    try std.testing.expectEqual(probe.Action.registers, (try probe.parse(&registers)).action);
    try std.testing.expectEqual(probe.Action.halt, (try probe.parse(&halt)).action);
    try std.testing.expectEqual(probe.Action.cont, (try probe.parse(&resume_args)).action);
    try std.testing.expectEqual(probe.Action.step, (try probe.parse(&step_args)).action);
}

test "probe ctl bounds memory reads" {
    const valid = [_][]const u8{ "ra8_emulator", "ctl", "probe", "star", "2331", "read", "0x02000000", "8" };
    const too_long = [_][]const u8{ "ra8_emulator", "ctl", "probe", "star", "2331", "read", "0x02000000", "257" };
    const request = try probe.parse(&valid);
    try std.testing.expectEqual(@as(u32, 0x02000000), request.address);
    try std.testing.expectEqual(@as(u16, 8), request.length);
    try std.testing.expectError(error.BadLength, probe.parse(&too_long));
}

fn answer(listener: *std.Io.net.Server, packet: []const u8) anyerror!void {
    const io = std.testing.io;
    var stream = try listener.accept(io);
    defer stream.close(io);
    var buffer: [32]u8 = undefined;
    var reader = stream.reader(io, &buffer);
    var request: [5]u8 = undefined;
    for (&request) |*byte| {
        byte.* = try reader.interface.takeByte();
    }
    try std.testing.expectEqualStrings("$g#67", &request);
    try host.sock.ready.sendAll(io, stream.socket.handle, packet, 1000);
    var ack: [1]u8 = undefined;
    _ = host.sock.ready.takeByte(io, stream.socket.handle, &ack, false);
}

test "probe control shared RSP adapter checks checksums and escapes response JSON" {
    const io = std.testing.io;
    var listener = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    defer listener.deinit(io);
    var future = try io.concurrent(answer, .{ &listener, "$\"#22" });
    defer future.cancel(io) catch {};
    var storage: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&storage);
    try probe.execute(io, .{ .host = "127.0.0.1", .port = listener.socket.address.getPort(), .action = .registers }, &out);
    try future.await(io);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("\"", parsed.value.object.get("registers_rsp").?.string);
}

test "probe control rejects corrupt RSP replies" {
    const io = std.testing.io;
    var listener = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    defer listener.deinit(io);
    var future = try io.concurrent(answer, .{ &listener, "$00#00" });
    defer future.cancel(io) catch {};
    var storage: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&storage);
    try std.testing.expectError(error.BadChecksum, probe.execute(io, .{ .host = "127.0.0.1", .port = listener.socket.address.getPort(), .action = .registers }, &out));
}

test "probe control silent provider times out instead of retaining a target indefinitely" {
    const io = std.testing.io;
    var listener = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    defer listener.deinit(io);
    var storage: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&storage);
    try std.testing.expectError(error.Timeout, probe.execute(io, .{ .host = "127.0.0.1", .port = listener.socket.address.getPort(), .action = .registers }, &out));
}
