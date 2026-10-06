//! `serve --listen unix:PATH|tcp:[HOST]:PORT` (RA8EMU-736): bind, then
//! serve one client at a time until SIGINT or SIGTERM. An empty host or
//! `localhost` binds 127.0.0.1; any other host must be an IP literal. The
//! bound address goes to stderr, and a Unix socket path is removed on exit.
const std = @import("std");
const served = @import("../rpc/session_server.zig");
const Connection = @import("../rpc/socket_transport.zig").Connection;
const loop = @import("serve_loop.zig");

/// How long the accept loop waits for a client before checking for a stop.
const accept_wait_ms = 20;

pub const Spec = union(enum) {
    unix: []const u8,
    tcp: std.net.Address,

    pub fn parse(text: []const u8) !Spec {
        if (std.mem.startsWith(u8, text, "unix:")) {
            const path = text["unix:".len..];
            if (path.len == 0) return error.BadListen;
            return .{ .unix = path };
        }
        if (!std.mem.startsWith(u8, text, "tcp:")) return error.BadListen;
        const rest = text["tcp:".len..];
        const colon = std.mem.lastIndexOfScalar(u8, rest, ':') orelse return error.BadListen;
        const port = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch return error.BadListen;
        const host = std.mem.trim(u8, rest[0..colon], "[]");
        const named = if (host.len == 0 or std.mem.eql(u8, host, "localhost")) "127.0.0.1" else host;
        return .{ .tcp = std.net.Address.parseIp(named, port) catch return error.BadListen };
    }
};

/// Bind `spec` and answer clients one after another until a stop signal.
pub fn serve(spec: Spec, context: *served.Context, buffers: loop.Buffers) !void {
    const address = switch (spec) {
        .unix => |path| try std.net.Address.initUnix(path),
        .tcp => |tcp| tcp,
    };
    var server = try address.listen(.{ .reuse_address = spec == .tcp });
    defer server.deinit();
    defer switch (spec) {
        .unix => |path| std.fs.cwd().deleteFile(path) catch {},
        .tcp => {},
    };
    catchStops();
    switch (spec) {
        .unix => |path| std.debug.print("serve: listening on unix:{s}\n", .{path}),
        .tcp => std.debug.print("serve: listening on tcp:{}\n", .{server.listen_address}),
    }
    while (!loop.stopping.load(.acquire)) {
        if (!try ready(server.stream.handle)) continue;
        const client = try server.accept();
        var connection: Connection = .{ .stream = client.stream };
        defer connection.close();
        loop.answer(context, connection.transport(), client.stream.handle, .socket, buffers) catch |err| {
            std.debug.print("serve: client dropped: {s}\n", .{@errorName(err)});
        };
    }
}

/// True when a client is waiting on the listening socket.
fn ready(fd: std.posix.fd_t) !bool {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    return try std.posix.poll(&fds, accept_wait_ms) != 0;
}

/// SIGINT and SIGTERM end the serve cleanly at the next idle check.
fn catchStops() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = onStop },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
}

fn onStop(_: i32) callconv(.c) void {
    loop.stopping.store(true, .release);
}
