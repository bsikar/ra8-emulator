//! Blocking Unix clients handle pathname errno at the syscall boundary.
const builtin = @import("builtin");
const std = @import("std");

const posix = std.posix;

pub fn connect(io: std.Io, path: []const u8) !std.Io.net.Stream {
    var address: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = @splat(0) };
    if (path.len > address.path.len) return error.NameTooLong;
    @memcpy(address.path[0..path.len], path);
    const len: posix.socklen_t = @intCast(@offsetOf(posix.sockaddr.un, "path") + path.len +
        @intFromBool(path.len < address.path.len));
    const flags: u32 = posix.SOCK.STREAM | if (builtin.os.tag.isDarwin()) 0 else posix.SOCK.CLOEXEC;
    try io.checkCancel();
    const opened = while (true) {
        const result = posix.system.socket(posix.AF.UNIX, flags, 0);
        switch (posix.errno(result)) {
            .SUCCESS => break result,
            .INTR => try io.checkCancel(),
            .AFNOSUPPORT, .PROTONOSUPPORT => return error.AddressFamilyUnsupported,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
    };
    const fd: posix.fd_t = @intCast(opened);
    errdefer _ = std.c.close(fd);
    if (builtin.os.tag.isDarwin()) {
        while (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) {
            if (posix.errno(@as(c_int, -1)) != .INTR) return error.Unexpected;
            try io.checkCancel();
        }
    }
    try setBlocking(io, fd, false);
    while (true) {
        try io.checkCancel();
        const result = posix.errno(posix.system.connect(fd, @ptrCast(&address), len));
        switch (result) {
            .SUCCESS, .ISCONN => break,
            .INTR => continue,
            // Linux returns EAGAIN without starting a connection when the
            // listener queue is full. Retry connect rather than SO_ERROR.
            .AGAIN => try pause(io),
            .INPROGRESS, .ALREADY => {
                try pending(io, fd);
                break;
            },
            else => try failure(result),
        }
    }
    try setBlocking(io, fd, true);
    return .{ .socket = .{ .handle = fd, .address = .{ .ip4 = .loopback(0) } } };
}

fn pause(io: std.Io) !void {
    try std.Io.sleep(io, .fromMilliseconds(5), .awake);
}

fn setBlocking(io: std.Io, fd: posix.fd_t, blocking: bool) !void {
    const old = while (true) {
        const result = std.c.fcntl(fd, std.c.F.GETFL);
        if (result >= 0) break result;
        if (posix.errno(result) != .INTR) return error.Unexpected;
        try io.checkCancel();
    };
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    const flags = if (blocking) old & ~nonblock else old | nonblock;
    while (std.c.fcntl(fd, std.c.F.SETFL, flags) < 0) {
        if (posix.errno(@as(c_int, -1)) != .INTR) return error.Unexpected;
        try io.checkCancel();
    }
}

fn pending(io: std.Io, fd: posix.fd_t) !void {
    while (true) {
        try io.checkCancel();
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
        if (try posix.poll(&fds, 0) != 0) return finished(io, fd);
        try pause(io);
    }
}

fn finished(io: std.Io, fd: posix.fd_t) !void {
    var code: c_int = 0;
    var size: posix.socklen_t = @sizeOf(c_int);
    while (std.c.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, &code, &size) < 0) {
        if (posix.errno(@as(c_int, -1)) != .INTR) return error.Unexpected;
        try io.checkCancel();
    }
    return failure(@fromBackingInt(@intCast(code)));
}

fn failure(code: posix.E) !void {
    switch (code) {
        .SUCCESS, .ISCONN => {},
        .NOTSOCK, .PROTOTYPE, .CONNREFUSED => return error.ConnectionRefused,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .LOOP => return error.SymLinkLoop,
        .ROFS => return error.ReadOnlyFileSystem,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        else => return error.Unexpected,
    }
}
