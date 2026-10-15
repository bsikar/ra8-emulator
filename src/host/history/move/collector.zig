//! The owner of a proxy child its caller has to let go. It starts with the
//! proxy, before the child is sent anything, so no operation is admitted
//! without an owner for the child and a failure to start one refuses the
//! exchange before it begins. It parks until the caller either reaps the
//! child itself or hands it over.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const Shared = struct {
    io: std.Io,
    event: std.Io.Event = .unset,
    /// Written once before `event` is set; -1 means released.
    handle: linux.fd_t = -1,
};

pub const Collector = struct {
    shared: *Shared,

    pub fn start(io: std.Io) !Collector {
        if (builtin.os.tag != .linux) return error.OperationUnsupported;
        const shared = try std.heap.page_allocator.create(Shared);
        errdefer std.heap.page_allocator.destroy(shared);
        shared.* = .{ .io = io };
        const thread = try std.Thread.spawn(.{}, run, .{shared});
        thread.detach();
        return .{ .shared = shared };
    }

    /// The caller reaped its child itself, or never had one: the collector
    /// ends without acting. Neither this nor `adopt` may follow the other.
    pub fn release(self: Collector) void {
        self.shared.handle = -1;
        self.shared.event.set(self.shared.io);
    }

    /// From here the collector owns `handle`, the caller's pidfd of its own
    /// unreaped child, and the child behind it.
    pub fn adopt(self: Collector, handle: linux.fd_t) void {
        self.shared.handle = handle;
        self.shared.event.set(self.shared.io);
    }
};

fn run(shared: *Shared) void {
    shared.event.waitUncancelable(shared.io);
    const handle = shared.handle;
    std.heap.page_allocator.destroy(shared);
    if (handle >= 0) collect(handle);
}

/// Continue the child whenever it stops and reap it the moment it ends, so
/// no zombie holds its place. Continuing releases nothing: the child can
/// only relay what its caller already wrote and then end with its peer. It
/// is never killed. Every signal and wait goes through the pidfd, which
/// names this one process even after its PID is reused.
pub fn collect(handle: linux.fd_t) void {
    defer _ = linux.close(handle);
    while (true) {
        _ = linux.pidfd_send_signal(handle, .CONT, null, 0);
        var info: linux.siginfo_t = undefined;
        switch (linux.errno(linux.waitid(.PIDFD, handle, &info, linux.W.EXITED | linux.W.STOPPED, null))) {
            .SUCCESS => if (info.code != @backingInt(linux.CLD.STOPPED)) return,
            .INTR => {},
            else => return,
        }
    }
}
