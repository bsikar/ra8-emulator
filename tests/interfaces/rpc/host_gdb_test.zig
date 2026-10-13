const std = @import("std");
const ra8 = @import("ra8");
const ready = ra8.host.sock.ready;
const listener_mod = ra8.rpc.host_listener;
const served_setup = ra8.rpc.served_setup;
const io = std.testing.io;

fn homePath(gpa: std.mem.Allocator) ![]u8 {
    const parent = if (@import("builtin").os.tag == .windows)
        try (std.process.Environ{ .block = .global }).getAlloc(gpa, "TEMP")
    else
        try gpa.dupe(u8, "/tmp");
    defer gpa.free(parent);
    return std.fmt.allocPrint(gpa, "{s}/ra8_gdb_{d}", .{ parent, std.Io.Timestamp.now(io, .awake).nanoseconds });
}

fn packet(host: anytype, client: std.Io.net.Stream, out: []u8) ![]const u8 {
    const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + 2000;
    var used: usize = 0;
    while (std.Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) {
        host.pump();
        if (!(try ready.wait(io, client.socket.handle, 0)).any()) {
            try io.sleep(.fromMilliseconds(1), .awake);
            continue;
        }
        var byte: [1]u8 = undefined;
        if ((ready.takeByte(io, client.socket.handle, &byte, false) orelse return error.LinkDown) == 0) return error.LinkDown;
        if (used == out.len) return error.Overflow;
        out[used] = byte[0];
        used += 1;
        if (used >= 3 and out[used - 3] == '#') return out[0..used];
    }
    return error.Timeout;
}

test "host GDB serves ordinary packets, reconnects and drops a slow peer in finite time" {
    const gpa = std.testing.allocator;
    const home = try homePath(gpa);
    defer gpa.free(home);
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("HOME", home);
    var opened: served_setup.Served = undefined;
    try opened.open(gpa, io, "tests/fixtures/fpu/fp_basic.elf", null);
    defer opened.deinit();
    var bound = try listener_mod.Listener.bind(gpa, io, &env);
    defer bound.deinit();
    const port = try bound.addGdb("fixture.elf", opened.context.session);
    const host = bound.gdb.items[0];
    const address = std.Io.net.IpAddress{ .ip4 = .loopback(port) };
    for (0..4) |_| {
        const client = try address.connect(io, .{ .mode = .stream });
        var live = true;
        defer if (live) client.close(io);
        try ready.sendAll(io, client.socket.handle, "$qSupported#37", 1000);
        var buffer: [1024]u8 = undefined;
        const response = try packet(host, client, &buffer);
        try std.testing.expect(std.mem.indexOf(u8, response, "PacketSize=") != null);
        client.close(io);
        live = false;
        const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + 2000;
        while (host.client != null and std.Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) host.pump();
        try std.testing.expect(host.client == null);
    }
    const client = try address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    try takeClient(host);
    try smallBuffers(host.client.?.stream, client);
    const bytes = try gpa.alloc(u8, 16 * 1024 * 1024);
    defer gpa.free(bytes);
    @memset(bytes, 'g');
    var saturated = false;
    for (0..16) |_| {
        ready.sendAll(io, host.client.?.stream.socket.handle, bytes, 20) catch |err| {
            try std.testing.expectEqual(error.Timeout, err);
            saturated = true;
            break;
        };
    }
    try std.testing.expect(saturated);
    try blockSmallReply(host.client.?.stream);
    try ready.sendAll(io, client.socket.handle, "$qSupported#37", 1000);
    const start = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    while (host.client != null and std.Io.Timestamp.now(io, .awake).toMilliseconds() - start < 2000) host.pump();
    try std.testing.expect(host.client == null);
}

/// A frame pump may observe accept readiness after connect has returned.
fn takeClient(host: anytype) !void {
    const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + 2000;
    while (std.Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) {
        host.pump();
        if (host.client != null) return;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.Timeout;
}

/// Limit the test-owned queues on POSIX; Windows std handles use native AFD.
fn smallBuffers(server: std.Io.net.Stream, client: std.Io.net.Stream) !void {
    if (@import("builtin").os.tag == .windows) return;
    const bytes: c_int = 4096;
    try std.posix.setsockopt(server.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&bytes));
    try std.posix.setsockopt(client.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, std.mem.asBytes(&bytes));
}

/// A large-write timeout alone does not prove that a tiny reply is blocked.
fn blockSmallReply(server: std.Io.net.Stream) !void {
    const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + 2000;
    while (std.Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) {
        ready.sendAll(io, server.socket.handle, "g", 20) catch |err| {
            try std.testing.expectEqual(error.Timeout, err);
            return;
        };
    }
    return error.Timeout;
}

test "host GDB sends port 0's console text as O packets ahead of the stop reply" {
    const gpa = std.testing.allocator;
    const home = try homePath(gpa);
    defer gpa.free(home);
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("HOME", home);
    var opened: served_setup.Served = undefined;
    try opened.open(gpa, io, "tests/fixtures/fpu/fp_basic.elf", null);
    defer opened.deinit();
    var bound = try listener_mod.Listener.bind(gpa, io, &env);
    defer bound.deinit();
    const port = try bound.addGdb("fixture.elf", opened.context.session);
    const host = bound.gdb.items[0];
    const address = std.Io.net.IpAddress{ .ip4 = .loopback(port) };
    const client = try address.connect(io, .{ .mode = .stream });
    defer client.close(io);
    try takeClient(host);

    // Print through stimulus port 0 while the target is paused.
    const itm = ra8.chip.periph.itm;
    const itmp = try opened.context.session.itmPort(opened.context.session.currentCore());
    _ = itmp.write(itm.offsets.tcr, itm.tcr_bits.itmena, 4);
    _ = itmp.write(itm.offsets.ter, 1, 4);
    for ("host console\n") |ch| _ = itmp.write(itm.offsets.stim0, ch, 1);

    // A single step is a resume: its console text goes out as O packets
    // before the stop reply, and the port is then empty.
    try ready.sendAll(io, client.socket.handle, "$s#73", 1000);
    var buffer: [1024]u8 = undefined;
    const console_packet = try packet(host, client, &buffer);
    try std.testing.expect(std.mem.startsWith(u8, console_packet, "$O"));
    const hex = console_packet[2 .. console_packet.len - 3];
    var said: [64]u8 = undefined;
    const said_len = hex.len / 2;
    try std.testing.expect(said_len <= said.len);
    try std.testing.expectEqual(@as(usize, 2 * said_len), hex.len);
    for (0..said_len) |at| {
        said[at] = try std.fmt.parseInt(u8, hex[at * 2 .. at * 2 + 2], 16);
    }
    try std.testing.expect(std.mem.startsWith(u8, said[0..said_len], "host console\n"));
    const stop = try packet(host, client, &buffer);
    try std.testing.expect(stop.len > 1 and (stop[1] == 'T' or stop[1] == 'S'));
    try std.testing.expectEqual(@as(usize, 0), itmp.output().len);
}
