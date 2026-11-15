//! `serve --listen unix:PATH|tcp:[HOST]:PORT` (RA8EMU-736): bind, then
//! serve one client at a time until SIGINT, SIGTERM, SIGHUP or SIGQUIT (a
//! closed terminal or a supervisor stop ends it like the others). An empty host or
//! `localhost` binds 127.0.0.1; any other host must be an IP literal. The
//! bound address goes to stderr, and a Unix socket path is removed on exit.

const builtin = @import("builtin");
const served = @import("ra8_rpc").session.server;
const Service = @import("ra8_rpc").artifacts.service.Service;
const sock_ready = @import("ra8_host").sock.ready;
const sock_unix = @import("ra8_host").sock.unix;
const std = @import("std");
const win32 = @import("ra8_host").win32;

const Connection = @import("ra8_rpc").ws_transport.Connection;
const loop = @import("loop.zig");

/// How long the accept loop waits for a client before checking for a stop.
const accept_wait_ms = 20;

pub const Spec = union(enum) {
    unix: []const u8,
    tcp: std.Io.net.IpAddress,

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
        return .{ .tcp = std.Io.net.IpAddress.parse(named, port) catch return error.BadListen };
    }
};

const Server = union(enum) {
    unix: sock_unix.Listener,
    tcp: std.Io.net.Server,

    fn deinit(self: *Server, io: std.Io) void {
        switch (self.*) {
            .unix => |*u| u.deinit(io),
            .tcp => |*t| t.deinit(io),
        }
    }

    fn ready(self: *const Server, io: std.Io) !bool {
        return switch (self.*) {
            .unix => |*u| (try sock_unix.wait(io, u.handle(), accept_wait_ms)).any(),
            .tcp => |*t| (try sock_ready.wait(io, t.socket.handle, accept_wait_ms)).any(),
        };
    }

    fn accept(self: *Server, io: std.Io) !std.Io.net.Stream {
        return switch (self.*) {
            .unix => |*u| u.accept(io),
            .tcp => |*t| t.accept(io),
        };
    }
};

/// Bind `spec` and answer clients one after another until a stop signal.
pub fn serve(io: std.Io, spec: Spec, context: *served.Context, buffers: loop.Buffers) !void {
    return serveWith(io, spec, context, buffers, null);
}

pub fn serveManaged(io: std.Io, spec: Spec, service: *Service) !void {
    return serveWith(io, spec, null, .{ .rx = &.{}, .tx = &.{} }, service);
}

fn serveWith(io: std.Io, spec: Spec, context: ?*served.Context, buffers: loop.Buffers, service: ?*Service) !void {
    var server: Server = switch (spec) {
        .unix => |path| .{ .unix = try sock_unix.Listener.bind(io, path) },
        .tcp => |*tcp| .{ .tcp = try tcp.listen(io, .{ .reuse_address = true }) },
    };
    defer server.deinit(io);
    catchStops();
    switch (spec) {
        .unix => |path| std.debug.print("serve: listening on unix:{s}\n", .{path}),
        .tcp => std.debug.print("serve: listening on tcp:{f}\n", .{server.tcp.socket.address}),
    }
    while (!loop.stopping.load(.acquire)) {
        const active = if (service) |owner| &owner.active.context else context.?;
        if (active.session.persistent_recorder) |rec| try rec.maybeCommit(rec.now());
        if (!try server.ready(io)) continue;
        const client = server.accept(io) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        answerClient(io, spec, client, active, buffers, service);
    }
}

/// SIGINT, SIGTERM, SIGHUP and SIGQUIT end the serve cleanly at the next idle
/// check, so the exit is 0 and a Unix socket path is removed. Windows
/// has no POSIX signals, so Ctrl+C, Ctrl+Break and console close do it there.
fn catchStops() void {
    if (builtin.os.tag == .windows) {
        _ = win32.SetConsoleCtrlHandler(onConsoleStop, .TRUE);
        return;
    }
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = onStop },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.HUP, &action, null);
    std.posix.sigaction(std.posix.SIG.QUIT, &action, null);
}

fn onStop(_: std.posix.SIG) callconv(.c) void {
    loop.stopping.store(true, .release);
}

fn onConsoleStop(_: win32.DWORD) callconv(.winapi) win32.BOOL {
    loop.stopping.store(true, .release);
    return .TRUE;
}

/// True when `address` is loopback, the only TCP listener that may serve
/// state files without --allow-state-files (RA8EMU-1175).
pub fn isLoopback(address: std.Io.net.IpAddress) bool {
    return switch (address) {
        .ip4 => |v| v.bytes[0] == 127,
        .ip6 => |v| std.mem.allEqual(u8, v.bytes[0..15], 0) and v.bytes[15] == 1,
    };
}

/// True when snapshot and restore may be served on `spec`: any Unix socket,
/// a loopback TCP listener, or a TCP listener the operator opened to state
/// files with --allow-state-files (RA8EMU-1175).
pub fn allowsState(spec: Spec, allow_state_files: bool) bool {
    return switch (spec) {
        .unix => true,
        .tcp => |address| allow_state_files or isLoopback(address),
    };
}

fn answerClient(
    io: std.Io,
    spec: Spec,
    client: std.Io.net.Stream,
    active: *served.Context,
    buffers: loop.Buffers,
    service: ?*Service,
) void {
    var connection = if (spec == .unix) Connection.fromUnix(io, client) else Connection.init(io, client);
    defer connection.close();
    const link: loop.Link = if (spec == .unix and builtin.os.tag == .windows) .unix_socket else .socket;
    const done = if (service) |owner|
        loop.answerManaged(io, owner, connection.transport(), client.socket.handle, link)
    else
        loop.answer(io, active, connection.transport(), client.socket.handle, link, buffers);
    done catch |err| {
        std.debug.print("serve: client dropped: {s}\n", .{@errorName(err)});
    };
}
