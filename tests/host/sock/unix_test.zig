//! Tests for src/host/sock/unix.zig (RA8EMU-1279): Windows Winsock2 AF_UNIX
//! listener/client lifecycle, nonblocking wait/read/sendAll/takeByte, stale
//! socket unlink before bind, active-listener protection, and <108-byte sun_path.
const std = @import("std");
const builtin = @import("builtin");
const ra8 = @import("ra8");
const sock_unix = ra8.host.sock.unix;
const on_windows = builtin.os.tag == .windows;

fn testSocketPath(gpa: std.mem.Allocator, sub: []const u8, name: []const u8) ![]u8 {
    if (!on_windows) return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/{s}", .{ sub, name });
    const env: std.process.Environ = .{ .block = .global };
    const temp = try env.getAlloc(gpa, "TEMP");
    defer gpa.free(temp);
    return std.fmt.allocPrint(gpa, "{s}\\ra8u_{s}_{s}", .{ temp, sub, name });
}

fn readUntilBytes(io: std.Io, handle: sock_unix.Handle, out: []u8) !usize {
    var got: usize = 0;
    const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + 2000;
    while (got < out.len) {
        if (std.Io.Timestamp.now(io, .awake).toMilliseconds() >= deadline) return error.TimedOut;
        const ready = try sock_unix.wait(io, handle, 20);
        if (!ready.any()) continue;
        const n = sock_unix.read(io, handle, out[got..]) catch |err| {
            if (got > 0) return got;
            return err;
        };
        if (n == 0) return got;
        got += n;
    }
    return got;
}

test "unix.Listener and unix.connect roundtrip wait, peek, read, sendAll, EOF and unlink" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testSocketPath(gpa, &tmp.sub_path, "rt.sock");
    defer gpa.free(path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var listener = try sock_unix.Listener.bind(io, path);
    errdefer listener.deinit(io);
    try std.Io.Dir.cwd().access(io, path, .{});
    try std.testing.expect(!(try sock_unix.wait(io, listener.handle(), 0)).any());
    try std.testing.expectError(error.WouldBlock, listener.accept(io));

    const client = try sock_unix.connect(io, path);
    defer sock_unix.close(io, client.socket.handle);
    try std.testing.expect((try sock_unix.wait(io, listener.handle(), 1000)).readable);
    const accepted = try listener.accept(io);
    defer sock_unix.close(io, accepted.socket.handle);

    var idle: [8]u8 = undefined;
    try std.testing.expect(!(try sock_unix.wait(io, accepted.socket.handle, 0)).any());
    try std.testing.expectEqual(@as(usize, 0), try sock_unix.read(io, accepted.socket.handle, &idle));
    var one: [1]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), sock_unix.takeByte(io, accepted.socket.handle, &one, true));

    try sock_unix.sendAll(io, client.socket.handle, "hello-unix", 1000);
    try std.testing.expect((try sock_unix.wait(io, accepted.socket.handle, 1000)).readable);
    try std.testing.expectEqual(@as(?usize, 1), sock_unix.takeByte(io, accepted.socket.handle, &one, true));
    try std.testing.expectEqual(@as(u8, 'h'), one[0]);

    var buf: [16]u8 = undefined;
    const n = try readUntilBytes(io, accepted.socket.handle, buf[0..10]);
    try std.testing.expectEqualStrings("hello-unix", buf[0..n]);

    try sock_unix.sendAll(io, accepted.socket.handle, "pong", 1000);
    const m = try readUntilBytes(io, client.socket.handle, buf[0..4]);
    try std.testing.expectEqualStrings("pong", buf[0..m]);

    try sock_unix.shutdownSend(client.socket.handle);
    const eof_ready = try sock_unix.wait(io, accepted.socket.handle, 1000);
    try std.testing.expect(eof_ready.any());
    if (eof_ready.readable) {
        const peeked = sock_unix.takeByte(io, accepted.socket.handle, &one, true);
        try std.testing.expect(peeked == null or peeked.? == 0);
    }

    listener.deinit(io);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, path, .{}));
}

test "unix.Listener.bind unlinks stale socket files while protecting live listeners" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testSocketPath(gpa, &tmp.sub_path, "stale.sock");
    defer gpa.free(path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    // Leftover regular file is unlinked before binding.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "stale" });
    var first = try sock_unix.Listener.bind(io, path);
    // Live active listener rejects a second concurrent bind with AddressInUse.
    try std.testing.expectError(error.AddressInUse, sock_unix.Listener.bind(io, path));

    // Confirm first listener still serves clients cleanly.
    const probe = try sock_unix.connect(io, path);
    sock_unix.close(io, probe.socket.handle);

    // Simulate a crashed process leaving an orphaned socket reparse file on disk.
    sock_unix.close(io, first.handle());
    var reborn = try sock_unix.Listener.bind(io, path);
    defer reborn.deinit(io);
    const client = try sock_unix.connect(io, path);
    defer sock_unix.close(io, client.socket.handle);
    try std.testing.expect((try sock_unix.wait(io, reborn.handle(), 1000)).readable);
    const peer = try reborn.accept(io);
    sock_unix.close(io, peer.socket.handle);
}

test "unix.Listener.bind preserves symlinks to files, missing paths and live sockets" {
    if (on_windows) return error.SkipZigTest; // Windows AF_UNIX uses reparse points itself.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try testSocketPath(gpa, &tmp.sub_path, "target");
    defer gpa.free(target);
    const link = try testSocketPath(gpa, &tmp.sub_path, "link");
    defer gpa.free(link);
    try tmp.dir.symLink(io, "target", "link", .{});
    try std.testing.expectError(error.AddressInUse, sock_unix.Listener.bind(io, link));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = "keep" });
    try std.testing.expectError(error.AddressInUse, sock_unix.Listener.bind(io, link));
    var bytes: [4]u8 = undefined;
    const file = try tmp.dir.openFile(io, "target", .{});
    defer file.close(io);
    try std.testing.expectEqual(bytes.len, try file.readPositionalAll(io, &bytes, 0));
    try std.testing.expectEqualStrings("keep", &bytes);
    try tmp.dir.deleteFile(io, "target");
    var listener = try sock_unix.Listener.bind(io, target);
    defer listener.deinit(io);
    try std.testing.expectError(error.AddressInUse, sock_unix.Listener.bind(io, link));
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, (try tmp.dir.statFile(io, "link", .{
        .follow_symlinks = false,
    })).kind);
    const client = try sock_unix.connect(io, target);
    defer client.close(io);
    try std.testing.expect((try sock_unix.wait(io, listener.handle(), 1000)).readable);
}

test "unix.Listener.bind preserves directories at the requested path" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "directory", .default_dir);
    const path = try testSocketPath(gpa, &tmp.sub_path, "directory");
    defer gpa.free(path);
    if (on_windows) try std.Io.Dir.cwd().createDir(io, path, .default_dir);
    defer if (on_windows) std.Io.Dir.cwd().deleteDir(io, path) catch {};
    try std.testing.expect(std.meta.isError(sock_unix.Listener.bind(io, path)));
    try std.testing.expectEqual(std.Io.File.Kind.directory, (try std.Io.Dir.cwd().statFile(io, path, .{})).kind);
}

test "unix enforces <108-byte sun_path, rejects invalid paths, and fails missing targets" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try testSocketPath(gpa, &tmp.sub_path, "");
    defer gpa.free(base);

    const exact_len = sock_unix.max_path_len;
    if (base.len + 6 <= exact_len) {
        const pad_len = exact_len - base.len - ".sock".len;
        const pad = try gpa.alloc(u8, pad_len);
        defer gpa.free(pad);
        @memset(pad, 'a');
        const max_ok = try std.fmt.allocPrint(gpa, "{s}{s}.sock", .{ base, pad });
        defer gpa.free(max_ok);
        defer std.Io.Dir.cwd().deleteFile(io, max_ok) catch {};
        try std.testing.expectEqual(exact_len, max_ok.len);
        var listener = try sock_unix.Listener.bind(io, max_ok);
        defer listener.deinit(io);
        const client = try sock_unix.connect(io, max_ok);
        sock_unix.close(io, client.socket.handle);
    }

    const too_long = try gpa.alloc(u8, sock_unix.max_path_len + 1);
    defer gpa.free(too_long);
    @memset(too_long, 'x');
    if (on_windows) {
        @memcpy(too_long[0..3], "C:\\");
    } else {
        too_long[0] = '/';
    }
    try std.testing.expectError(error.NameTooLong, sock_unix.Listener.bind(io, too_long));
    try std.testing.expectError(error.NameTooLong, sock_unix.connect(io, too_long));

    if (on_windows) {
        try std.testing.expectError(error.AddressUnavailable, sock_unix.Listener.bind(io, ""));
        try std.testing.expectError(error.BadPathName, sock_unix.Listener.bind(io, "bad\x00path.sock"));
    }

    const missing = try testSocketPath(gpa, &tmp.sub_path, "missing.sock");
    defer gpa.free(missing);
    try std.testing.expect(std.meta.isError(sock_unix.connect(io, missing)));
}

test "socket_transport and ws_transport roundtrip over Unix domain sockets" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testSocketPath(gpa, &tmp.sub_path, "rpc.sock");
    defer gpa.free(path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var listener = try sock_unix.Listener.bind(io, path);
    defer listener.deinit(io);

    var client = try ra8.rpc.socket_transport.Connection.unix(io, path);
    defer client.close();
    try std.testing.expect((try sock_unix.wait(io, listener.handle(), 1000)).readable);
    const stream = try listener.accept(io);
    var server = ra8.rpc.ws_transport.Connection.fromUnix(io, stream);
    defer server.close();

    const ct = client.transport();
    const st = server.transport();
    try ct.vtable.send(ct.ctx, "PING");
    try std.testing.expect((try sock_unix.wait(io, server.stream.socket.handle, 1000)).any());
    var rx: [16]u8 = undefined;
    var got: usize = 0;
    while (got < 4) {
        got += try st.vtable.receive(st.ctx, rx[got..]);
        if (got < 4) try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqualStrings("PING", rx[0..4]);

    try st.vtable.send(st.ctx, "PONG");
    try std.testing.expect((try sock_unix.wait(io, client.stream.socket.handle, 1000)).any());
    got = 0;
    while (got < 4) {
        got += try ct.vtable.receive(ct.ctx, rx[got..]);
        if (got < 4) try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqualStrings("PONG", rx[0..4]);
}

test "unix sendAll surfaces BrokenPipe when peer closes before write" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testSocketPath(gpa, &tmp.sub_path, "pipe.sock");
    defer gpa.free(path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var listener = try sock_unix.Listener.bind(io, path);
    defer listener.deinit(io);

    const client = try sock_unix.connect(io, path);
    defer sock_unix.close(io, client.socket.handle);
    try std.testing.expect((try sock_unix.wait(io, listener.handle(), 1000)).readable);
    const server = try listener.accept(io);
    sock_unix.close(io, server.socket.handle);

    const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + 1000;
    var saw_broken = false;
    while (std.Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) {
        sock_unix.sendAll(io, client.socket.handle, "ping", 100) catch |err| {
            try std.testing.expectEqual(error.BrokenPipe, err);
            saw_broken = true;
            break;
        };
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    try std.testing.expect(saw_broken);
}

test "unix.Listener.bind preserves a live listener whose connection backlog is full" {
    if (on_windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testSocketPath(std.testing.allocator, &tmp.sub_path, "full.sock");
    defer std.testing.allocator.free(path);
    const address = try std.Io.net.UnixAddress.init(path);
    var listener = try address.listen(io, .{ .kernel_backlog = 1 });
    defer listener.deinit(io);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var native: std.posix.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(native.path[0..path.len], path);
    const length: std.posix.socklen_t = @intCast(@offsetOf(std.posix.sockaddr.un, "path") + path.len + 1);
    var clients: [8]sock_unix.Handle = undefined;
    var count: usize = 0;
    defer for (clients[0..count]) |fd| ra8.host.sock.close(fd);
    var pending = false;
    for (&clients) |*fd| {
        const opened = std.posix.system.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
        try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(opened));
        fd.* = @intCast(opened);
        count += 1;
        const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
        try std.testing.expect(std.c.fcntl(fd.*, std.c.F.SETFL, nonblock) == 0);
        const result = std.posix.errno(std.posix.system.connect(fd.*, @ptrCast(&native), length));
        const full = result == .AGAIN or result == .INPROGRESS or
            (builtin.os.tag == .macos and result == .CONNREFUSED);
        try std.testing.expect(result == .SUCCESS or full);
        pending = pending or full;
    }
    try std.testing.expect(pending);
    const before = try std.Io.Dir.cwd().statFile(io, path, .{});
    try std.testing.expectError(error.AddressInUse, sock_unix.Listener.bind(io, path));
    const after = try std.Io.Dir.cwd().statFile(io, path, .{});
    try std.testing.expectEqual(before.inode, after.inode);
}

test "unix.Listener.bind preserves a different Unix socket protocol at the same path" {
    if (on_windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testSocketPath(std.testing.allocator, &tmp.sub_path, "dgram.sock");
    defer std.testing.allocator.free(path);
    const fd = std.posix.system.socket(std.posix.AF.UNIX, std.posix.SOCK.DGRAM, 0);
    if (std.posix.errno(fd) != .SUCCESS) return error.SocketUnavailable;
    defer ra8.host.sock.close(@intCast(fd));
    var address: std.posix.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(address.path[0..path.len], path);
    const length: std.posix.socklen_t = @intCast(@offsetOf(std.posix.sockaddr.un, "path") + path.len + 1);
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(std.posix.system.bind(@intCast(fd), @ptrCast(&address), length)));
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const before = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    try std.testing.expectError(error.AddressInUse, sock_unix.Listener.bind(io, path));
    const after = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    try std.testing.expectEqual(before.inode, after.inode);
    try std.testing.expectEqual(before.kind, after.kind);
}
