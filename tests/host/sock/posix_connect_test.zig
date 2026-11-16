//! Unix client path errors and descriptor ownership.
const std = @import("std");
const builtin = @import("builtin");
const ra8 = @import("ra8");

const sock_unix = ra8.host.sock.unix;
const on_windows = builtin.os.tag == .windows;

test "unix.connect returns an error for a regular file without changing it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/file.sock", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "unchanged" });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    if (sock_unix.connect(io, path)) |stream| {
        sock_unix.close(io, stream.socket.handle);
        return error.ConnectedToRegularFile;
    } else |err| {
        if (!on_windows) try std.testing.expectEqual(error.ConnectionRefused, err);
    }
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .limited(32));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("unchanged", data);
}

test "unix.connect successful POSIX clients remain blocking and close on exec" {
    if (on_windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/live.sock", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    var listener = try sock_unix.Listener.bind(io, path);
    defer listener.deinit(io);
    const client = try sock_unix.connect(io, path);
    defer sock_unix.close(io, client.socket.handle);
    const fd_flags = std.c.fcntl(client.socket.handle, std.c.F.GETFD);
    try std.testing.expect(fd_flags >= 0);
    try std.testing.expect(fd_flags & std.c.FD_CLOEXEC != 0);
    const status = std.c.fcntl(client.socket.handle, std.c.F.GETFL);
    try std.testing.expect(status >= 0);
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    try std.testing.expectEqual(@as(c_int, 0), status & nonblock);
}

const Saturated = struct {
    listener: std.Io.net.Server,
    clients: [8]std.posix.fd_t = undefined,
    count: usize = 0,

    fn init(io: std.Io, path: []const u8) !Saturated {
        const address = try std.Io.net.UnixAddress.init(path);
        var result: Saturated = .{ .listener = try address.listen(io, .{ .kernel_backlog = 1 }) };
        errdefer result.deinit(io);
        var raw: std.posix.sockaddr.un = .{ .family = std.posix.AF.UNIX, .path = @splat(0) };
        @memcpy(raw.path[0..path.len], path);
        const len: std.posix.socklen_t = @intCast(@offsetOf(std.posix.sockaddr.un, "path") + path.len + 1);
        while (result.count < result.clients.len) {
            const opened = std.posix.system.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0);
            if (std.posix.errno(opened) != .SUCCESS) return error.SocketFailed;
            const fd: std.posix.fd_t = @intCast(opened);
            const outcome = std.posix.errno(std.posix.system.connect(fd, @ptrCast(&raw), len));
            if (outcome != .SUCCESS) {
                _ = std.c.close(fd);
                if (outcome == .AGAIN) return result;
                return error.UnexpectedConnectResult;
            }
            result.clients[result.count] = fd;
            result.count += 1;
        }
        return error.ListenerDidNotSaturate;
    }

    fn deinit(self: *Saturated, io: std.Io) void {
        for (self.clients[0..self.count]) |fd| _ = std.c.close(fd);
        self.listener.deinit(io);
    }
};

fn connectTask(io: std.Io, path: []const u8, entered: *std.atomic.Value(bool), done: *std.atomic.Value(bool)) !void {
    entered.store(true, .release);
    defer done.store(true, .release);
    const stream = try sock_unix.connect(io, path);
    sock_unix.close(io, stream.socket.handle);
}

fn releaseAfter(io: std.Io, listener: *std.Io.net.Server) !void {
    try std.Io.sleep(io, .fromMilliseconds(1000), .awake);
    const accepted = try listener.accept(io);
    accepted.close(io);
}

test "Linux saturated Unix backlog connect remains cancelable" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/full.sock", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    var full = try Saturated.init(io, path);
    defer full.deinit(io);
    var entered: std.atomic.Value(bool) = .init(false);
    var done: std.atomic.Value(bool) = .init(false);
    var future = try io.concurrent(connectTask, .{ io, path, &entered, &done });
    defer future.cancel(io) catch {};
    while (!entered.load(.acquire)) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    try std.Io.sleep(io, .fromMilliseconds(25), .awake);
    try std.testing.expect(!done.load(.acquire));
    // An old raw blocking connect would ignore cancellation. Release it after
    // one second so that implementation fails this test without hanging it.
    var release = try io.concurrent(releaseAfter, .{ io, &full.listener });
    defer release.cancel(io) catch {};
    const before = std.Io.Clock.awake.now(io).nanoseconds;
    try std.testing.expectError(error.Canceled, future.cancel(io));
    try std.testing.expect(std.Io.Clock.awake.now(io).nanoseconds - before < 500_000_000);
    try std.testing.expect(done.load(.acquire));
}

test "Linux saturated Unix backlog connect retries until an accept frees space" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/retry.sock", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    var full = try Saturated.init(io, path);
    defer full.deinit(io);
    var entered: std.atomic.Value(bool) = .init(false);
    var done: std.atomic.Value(bool) = .init(false);
    var future = try io.concurrent(connectTask, .{ io, path, &entered, &done });
    defer future.cancel(io) catch {};
    try std.Io.sleep(io, .fromMilliseconds(25), .awake);
    try std.testing.expect(!done.load(.acquire));
    const accepted = try full.listener.accept(io);
    defer accepted.close(io);
    try future.await(io);
    try std.testing.expect(done.load(.acquire));
}
