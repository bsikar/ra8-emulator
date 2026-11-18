//! Linux non-blocking 115200 8N1 reader for `/dev/serial/by-id/usb-SEGGER_J-Link*`.
const std = @import("std");

const posix = std.posix;

pub fn allowedByIdPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/dev/serial/by-id/usb-SEGGER_J-Link") and
        std.mem.endsWith(u8, path, "-if00") and
        std.mem.indexOf(u8, path, "..") == null;
}

const PollOutcome = union(enum) { idle, eof, bytes: usize };

pub const Port = struct {
    fd: posix.fd_t,

    pub fn open(path: []const u8) !Port {
        if (!allowedByIdPath(path)) return error.ForbiddenSerialPort;
        const path_z = posix.toPosixPath(path) catch return error.ForbiddenSerialPort;
        const rc = posix.system.open(&path_z, .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
            .NONBLOCK = true,
            .CLOEXEC = true,
        }, @as(posix.mode_t, 0));
        if (posix.errno(rc) != .SUCCESS) return error.SerialOpenFailed;
        const fd: posix.fd_t = @intCast(rc);
        errdefer _ = posix.system.close(fd);
        try configureRaw115200(fd);
        return .{ .fd = fd };
    }

    pub fn readBounded(
        self: *Port,
        io: std.Io,
        out: []u8,
        timeout_ms: u32,
        idle_ms: u32,
        cancel: ?*const std.atomic.Value(bool),
    ) !usize {
        const start = std.Io.Clock.awake.now(io).nanoseconds;
        const deadline = start + @as(i96, timeout_ms) * std.time.ns_per_ms;
        var last_rx = start;
        var total: usize = 0;
        while (total < out.len) {
            if (isCancelled(cancel)) return error.Canceled;
            const now = std.Io.Clock.awake.now(io).nanoseconds;
            if (now >= deadline or (total > 0 and now - last_rx >= @as(i96, idle_ms) * std.time.ns_per_ms)) break;
            switch (try self.pollRead(out[total..@min(out.len, total + 256)])) {
                .idle => continue,
                .eof => break,
                .bytes => |n| {
                    total += n;
                    last_rx = std.Io.Clock.awake.now(io).nanoseconds;
                },
            }
        }
        return total;
    }

    fn pollRead(self: *Port, dest: []u8) !PollOutcome {
        var fds = [_]posix.pollfd{.{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, 20) catch return error.SerialReadFailed;
        if (ready == 0) return .idle;
        if (fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) return .eof;
        const n = posix.read(self.fd, dest) catch |err| switch (err) {
            error.WouldBlock => return .idle,
            else => return error.SerialReadFailed,
        };
        return if (n == 0) .eof else .{ .bytes = n };
    }

    pub fn close(self: *Port) void {
        if (self.fd >= 0) {
            _ = posix.system.close(self.fd);
            self.fd = -1;
        }
    }
};

fn isCancelled(cancel: ?*const std.atomic.Value(bool)) bool {
    const flag = cancel orelse return false;
    return flag.load(.acquire);
}

fn configureRaw115200(fd: posix.fd_t) !void {
    var tio = posix.tcgetattr(fd) catch return error.SerialConfigFailed;
    tio.iflag = .{};
    tio.oflag = .{};
    tio.lflag = .{};
    tio.cflag.CSIZE = .CS8;
    tio.cflag.CREAD = true;
    tio.cflag.CLOCAL = true;
    tio.cflag.PARENB = false;
    tio.cflag.CSTOPB = false;
    tio.ispeed = .B115200;
    tio.ospeed = .B115200;
    posix.tcsetattr(fd, .NOW, tio) catch return error.SerialConfigFailed;
}
