//! Cross-platform Unix domain stream sockets (RA8EMU-1279).
//! Windows routes AF_UNIX through Winsock2 (afunix.sys) rather than Zig's
//! raw \Device\Afd\Endpoint open, which exits AddressFamilyUnsupported on
//! Windows releases without AFD AF_UNIX support. POSIX delegates to std.Io.net.
const std = @import("std");
const builtin = @import("builtin");
const sock_path = @import("path.zig");
const sock_ready = @import("ready.zig");
const sock_common = @import("sock.zig");
const win_sock = @import("windows.zig");
const win32 = @import("../win32.zig");

const on_windows = builtin.os.tag == .windows;

pub const Handle = sock_ready.Handle;
pub const Ready = sock_ready.Ready;
pub const max_path_len: usize = 107;

const backlog: c_int = 128;
const connect_timeout_ms: i64 = 5000;
const probe_timeout_ms: i32 = 50;

pub const Error = sock_common.Error || error{
    NameTooLong,
    AddressInUse,
    AddressUnavailable,
    AddressFamilyUnsupported,
    BadPathName,
    FileNotFound,
};

const win = struct {
    const af_unix: c_int = 1;
    const sock_stream: c_int = 1;
    const wsa_addr_in_use: c_int = 10048;

    const SockaddrUn = extern struct {
        family: u16 = 1,
        path: [108]u8 = @splat(0),
    };

    extern "ws2_32" fn bind(s: win32.HANDLE, name: *const SockaddrUn, len: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn listen(s: win32.HANDLE, limit: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn accept(s: win32.HANDLE, addr: ?*anyopaque, len: ?*c_int) callconv(.winapi) win32.HANDLE;
    extern "ws2_32" fn connect(s: win32.HANDLE, name: *const SockaddrUn, len: c_int) callconv(.winapi) c_int;
};

/// Bound Unix domain stream listener that unlinks its path on deinit.
pub const Listener = struct {
    win_fd: if (on_windows) Handle else void = if (on_windows) win32.invalid_handle else {},
    posix_server: if (on_windows) void else std.Io.net.Server = if (on_windows) {} else undefined,
    path_buf: [max_path_len + 1]u8 = undefined,
    path_len: u8 = 0,
    unlink_on_deinit: bool = false,

    /// Bind and listen on `raw_path`, unlinking a stale socket file if no live listener responds.
    pub fn bind(io: std.Io, raw_path: []const u8) !Listener {
        var scratch: [std.fs.max_path_bytes]u8 = undefined;
        const path = try resolvePath(io, raw_path, &scratch);
        var self: Listener = .{};
        if (path.len > self.path_buf.len) return error.NameTooLong;
        @memcpy(self.path_buf[0..path.len], path);
        self.path_len = @intCast(path.len);
        self.unlink_on_deinit = !(path.len > 0 and path[0] == 0);
        if (on_windows) {
            self.win_fd = try bindWindows(io, path);
        } else {
            self.posix_server = try bindPosix(io, path);
        }
        return self;
    }

    pub fn handle(self: *const Listener) Handle {
        return if (on_windows) self.win_fd else self.posix_server.socket.handle;
    }

    pub fn accept(self: *Listener, io: std.Io) !std.Io.net.Stream {
        if (!on_windows) {
            if (!(try wait(io, self.handle(), 0)).readable) return error.WouldBlock;
            return self.posix_server.accept(io);
        }
        const client = win.accept(self.win_fd, null, null);
        if (client == win32.invalid_handle) return mapLastWinError();
        errdefer win_sock.close(client);
        try win_sock.setNonblocking(client);
        return wrapWinStream(client);
    }

    pub fn deinit(self: *Listener, io: std.Io) void {
        if (on_windows) {
            if (self.win_fd != win32.invalid_handle) {
                win_sock.close(self.win_fd);
                self.win_fd = win32.invalid_handle;
            }
        } else {
            self.posix_server.deinit(io);
        }
        if (self.unlink_on_deinit) {
            self.unlink_on_deinit = false;
            std.Io.Dir.cwd().deleteFile(io, self.path_buf[0..self.path_len]) catch {};
        }
    }
};

/// Connect to a Unix domain stream listener at `raw_path`.
pub fn connect(io: std.Io, raw_path: []const u8) !std.Io.net.Stream {
    var scratch: [std.fs.max_path_bytes]u8 = undefined;
    const path = try resolvePath(io, raw_path, &scratch);
    if (!on_windows) {
        const address = try std.Io.net.UnixAddress.init(path);
        return address.connect(io);
    }
    const addr = try buildSockaddr(path);
    const s = try win_sock.openSocket(win.af_unix, win.sock_stream);
    errdefer win_sock.close(s);
    if (win.connect(s, &addr, @sizeOf(win.SockaddrUn)) == 0) return wrapWinStream(s);
    const err = mapLastWinError();
    if (err != error.WouldBlock) return err;
    try waitWinConnect(io, s, connect_timeout_ms);
    return wrapWinStream(s);
}

pub fn wait(io: std.Io, handle: Handle, ms: i32) error{SystemResources}!Ready {
    if (!on_windows) return sock_ready.wait(io, handle, ms);
    const revents = win_sock.poll(handle, win32.poll_in, ms) catch return error.SystemResources;
    return .{
        .readable = (revents & win32.poll_in) != 0,
        .hung_up = (revents & (win32.poll_hup | win32.poll_err)) != 0,
    };
}

pub fn takeByte(io: std.Io, handle: Handle, byte: *[1]u8, peek: bool) ?usize {
    if (!on_windows) return sock_ready.takeByte(io, handle, byte, peek);
    const flags: c_int = if (peek) win32.msg_peek else 0;
    const got = win32.recv(handle, byte, 1, flags);
    if (got < 0) return null;
    return @intCast(got);
}

pub fn read(_: std.Io, handle: Handle, into: []u8) error{LinkDown}!usize {
    if (into.len == 0) return 0;
    if (!on_windows) {
        const got = std.c.recv(handle, into.ptr, into.len, @intCast(std.posix.MSG.DONTWAIT));
        if (got < 0) {
            if (std.posix.errno(got) == .AGAIN) return 0;
            return error.LinkDown;
        }
        return @intCast(got);
    }
    const len: c_int = @intCast(@min(into.len, std.math.maxInt(c_int)));
    const got = win32.recv(handle, into.ptr, len, 0);
    if (got == win_sock.socket_error) {
        if (win32.WSAGetLastError() == win32.wsa_would_block) return 0;
        return error.LinkDown;
    }
    return @intCast(got);
}

pub fn sendAll(io: std.Io, handle: Handle, bytes: []const u8, ms: u32) !void {
    if (!on_windows) return sock_ready.sendAll(io, handle, bytes, ms);
    const timeout = (std.Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } }).toDeadline(io);
    var at: usize = 0;
    while (at < bytes.len) {
        const remaining = timeout.toDurationFromNow(io).?.raw.toMilliseconds();
        if (remaining <= 0) return error.Timeout;
        const got = win_sock.sendBytes(handle, bytes[at..]) catch |err| switch (err) {
            error.WouldBlock => {
                const wait_ms: i32 = @intCast(@min(remaining, @as(i64, std.math.maxInt(i32))));
                const revents = win_sock.poll(handle, win32.poll_out, wait_ms) catch return error.BrokenPipe;
                if ((revents & (win32.poll_hup | win32.poll_err)) != 0 and (revents & win32.poll_out) == 0) {
                    return error.BrokenPipe;
                }
                continue;
            },
            error.ConnectionReset, error.BrokenPipe => return error.BrokenPipe,
            else => return err,
        };
        if (got == 0) return error.BrokenPipe;
        at += got;
    }
}

pub fn shutdownSend(handle: Handle) !void {
    if (!on_windows) return sock_common.shutdownSend(handle);
    return win_sock.shutdownSend(handle);
}

pub fn close(io: std.Io, handle: Handle) void {
    if (on_windows) {
        win_sock.close(handle);
        return;
    }
    const stream: std.Io.net.Stream = .{ .socket = .{ .handle = handle, .address = .{ .ip4 = .loopback(0) } } };
    stream.close(io);
}

fn resolvePath(io: std.Io, raw: []const u8, scratch: *[std.fs.max_path_bytes]u8) ![]const u8 {
    if (on_windows) {
        if (raw.len == 0) return error.AddressUnavailable;
        if (std.mem.indexOfScalar(u8, raw, 0) != null) return error.BadPathName;
        if (raw.len > max_path_len and std.fs.path.isAbsolute(raw)) return error.NameTooLong;
    }
    const resolved = try sock_path.unix(io, raw, scratch);
    const is_abstract = !on_windows and resolved.len > 0 and resolved[0] == 0;
    if (is_abstract) return resolved;
    const candidate = if (on_windows and resolved.len > max_path_len and !std.fs.path.isAbsolute(raw) and raw.len <= max_path_len)
        raw
    else
        resolved;
    if (candidate.len == 0) return error.AddressUnavailable;
    if (candidate.len > max_path_len) return error.NameTooLong;
    if (std.mem.indexOfScalar(u8, candidate, 0) != null) return error.BadPathName;
    return candidate;
}

fn buildSockaddr(path: []const u8) Error!win.SockaddrUn {
    if (path.len > max_path_len) return error.NameTooLong;
    var addr: win.SockaddrUn = .{};
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;
    return addr;
}

fn bindWindows(io: std.Io, path: []const u8) !Handle {
    const addr = try buildSockaddr(path);
    return tryBindWindows(&addr) catch |err| switch (err) {
        error.AddressInUse => {
            if (isLiveListenerWindows(io, &addr)) return error.AddressInUse;
            std.Io.Dir.cwd().deleteFile(io, path) catch return error.AddressInUse;
            return tryBindWindows(&addr);
        },
        else => return err,
    };
}

fn tryBindWindows(addr: *const win.SockaddrUn) !Handle {
    const s = try win_sock.openSocket(win.af_unix, win.sock_stream);
    errdefer win_sock.close(s);
    if (win.bind(s, addr, @sizeOf(win.SockaddrUn)) == win_sock.socket_error) return mapLastWinError();
    if (win.listen(s, backlog) == win_sock.socket_error) return mapLastWinError();
    return s;
}

fn bindPosix(io: std.Io, path: []const u8) !std.Io.net.Server {
    const address = try std.Io.net.UnixAddress.init(path);
    return address.listen(io, .{}) catch |err| switch (err) {
        error.AddressInUse => {
            if (address.isAbstract()) return error.AddressInUse;
            if (address.connect(io)) |probe| {
                probe.close(io);
                return error.AddressInUse;
            } else |_| {}
            std.Io.Dir.cwd().deleteFile(io, path) catch return error.AddressInUse;
            return address.listen(io, .{});
        },
        else => return err,
    };
}

fn isLiveListenerWindows(io: std.Io, addr: *const win.SockaddrUn) bool {
    const probe = win_sock.openSocket(win.af_unix, win.sock_stream) catch return false;
    defer win_sock.close(probe);
    if (win.connect(probe, addr, @sizeOf(win.SockaddrUn)) == 0) return true;
    if (mapLastWinError() != error.WouldBlock) return false;
    waitWinConnect(io, probe, probe_timeout_ms) catch |err| switch (err) {
        error.TimedOut => return true,
        else => return false,
    };
    return true;
}

fn waitWinConnect(io: std.Io, s: Handle, timeout_ms: i64) !void {
    const timeout = (std.Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } }).toDeadline(io);
    while (true) {
        const remaining = timeout.toDurationFromNow(io).?.raw.toMilliseconds();
        if (remaining <= 0) return error.TimedOut;
        const wait_ms: i32 = @intCast(@min(remaining, @as(i64, std.math.maxInt(i32))));
        const revents = try win_sock.poll(s, win32.poll_out, wait_ms);
        if (revents == 0) continue;
        try win_sock.finished(s);
        if ((revents & win32.poll_err) != 0 and (revents & win32.poll_out) == 0) return error.ConnectionRefused;
        return;
    }
}

fn wrapWinStream(handle: Handle) std.Io.net.Stream {
    return .{ .socket = .{ .handle = handle, .address = .{ .ip4 = .loopback(0) } } };
}

fn mapLastWinError() Error {
    return mapWinError(win32.WSAGetLastError());
}

fn mapWinError(code: c_int) Error {
    return switch (code) {
        2, 3, 10002 => error.FileNotFound,
        10047 => error.AddressFamilyUnsupported,
        win.wsa_addr_in_use => error.AddressInUse,
        10049 => error.AddressUnavailable,
        10063 => error.NameTooLong,
        else => win_sock.mapCode(code),
    };
}
