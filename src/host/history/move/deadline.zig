//! Monotonic bounds on a Linux caller's pipe reads and child reaping.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const Deadline = struct {
    end: std.Io.Timestamp,

    pub fn after(io: std.Io, ms: u64) Deadline {
        return .{ .end = std.Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(@intCast(ms))) };
    }

    /// Milliseconds left, rounded up; null once the bound has passed.
    pub fn left(self: Deadline, io: std.Io) ?i32 {
        const ns = std.Io.Timestamp.now(io, .awake).durationTo(self.end).nanoseconds;
        if (ns <= 0) return null;
        return @intCast(@min(@divTrunc(ns + std.time.ns_per_ms - 1, std.time.ns_per_ms), std.math.maxInt(i32)));
    }

    /// Fail once the bound has passed: a publication step may begin only
    /// inside it.
    pub fn live(self: Deadline, io: std.Io) !void {
        if (self.left(io) == null) return error.DeadlineExceeded;
    }

    /// The earlier of the two.
    pub fn min(self: Deadline, other: Deadline) Deadline {
        return if (self.end.durationTo(other.end).nanoseconds < 0) other else self;
    }

    /// Return once `stream` has bytes or its writers are gone.
    pub fn readable(self: Deadline, io: std.Io, stream: std.Io.File) !void {
        if (builtin.os.tag != .linux) return error.OperationUnsupported;
        return self.poll(io, stream.handle);
    }

    /// Return once the process behind `handle`, a pidfd the caller took
    /// from its own unreaped child, has exited.
    pub fn ended(self: Deadline, io: std.Io, handle: linux.fd_t) !void {
        if (builtin.os.tag != .linux) return error.OperationUnsupported;
        return self.poll(io, handle);
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

/// One operation's admission. It starts once, before any helper exists, and
/// no phase resets it: every phase deadline is the phase's own ceiling from
/// when the phase begins, and never later than the admission's end.
pub const Admission = struct {
    end: Deadline,

    pub fn begin(io: std.Io, total_ms: u64) Admission {
        return .{ .end = .after(io, total_ms) };
    }

    pub fn phase(self: Admission, io: std.Io, ms: u64) Deadline {
        return Deadline.after(io, ms).min(self.end);
    }

    /// Whether a verdict may still be published under this admission.
    pub fn open(self: Admission, io: std.Io) bool {
        return self.end.left(io) != null;
    }
};
