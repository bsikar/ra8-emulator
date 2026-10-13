//! Monotonic bounds on a Linux caller's pipe reads and child reaping.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const Deadline = struct {
    end: std.Io.Timestamp,

    pub fn after(io: std.Io, ms: u32) Deadline {
        return .{ .end = std.Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(ms)) };
    }

    /// Milliseconds left, rounded up; null once the bound has passed.
    pub fn left(self: Deadline, io: std.Io) ?i32 {
        const ns = std.Io.Timestamp.now(io, .awake).durationTo(self.end).nanoseconds;
        if (ns <= 0) return null;
        return @intCast(@min(@divTrunc(ns + std.time.ns_per_ms - 1, std.time.ns_per_ms), std.math.maxInt(i32)));
    }

    /// Return once `stream` has bytes or its writers are gone.
    pub fn readable(self: Deadline, io: std.Io, stream: std.Io.File) !void {
        if (builtin.os.tag != .linux) return error.OperationUnsupported;
        return self.poll(io, stream.handle);
    }

    /// Return once the caller's own unreaped child `pid` has exited. The
    /// child is still to be reaped, so its PID cannot have been reused.
    pub fn exited(self: Deadline, io: std.Io, pid: i32) !void {
        if (builtin.os.tag != .linux) return error.OperationUnsupported;
        const opened = linux.pidfd_open(pid, 0);
        if (linux.errno(opened) != .SUCCESS) return error.Unexpected;
        const fd: linux.fd_t = @intCast(opened);
        defer _ = linux.close(fd);
        return self.poll(io, fd);
    }

    fn poll(self: Deadline, io: std.Io, fd: linux.fd_t) !void {
        var fds = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        while (true) {
            const ms = self.left(io) orelse return error.DeadlineExceeded;
            switch (linux.errno(linux.poll(&fds, 1, ms))) {
                .SUCCESS => if (fds[0].revents != 0) return,
                .INTR => {},
                else => return error.Unexpected,
            }
        }
    }
};
