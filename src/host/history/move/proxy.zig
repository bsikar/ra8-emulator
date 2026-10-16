//! The spawned WSL proxy child: who owns it, who reaps it, and when it may
//! be signalled. Every signal and every wait for its exit goes through a
//! pidfd taken from the caller's own spawn while the child was unreaped.
//! Nothing a peer reports, its PID, birth, paths or digests, ever names a
//! process to signal, so a correct copy of another instance's fields
//! cannot end that instance.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const wire = @import("wire.zig");
const deadline = @import("deadline.zig");
const Collector = @import("collector.zig").Collector;
const Context = @import("context.zig").Context;

pub const Stage = enum { open, committed, reaped, abandoned };

pub const Proxy = struct {
    io: std.Io,
    child: std.process.Child,
    /// The child's pidfd, held until the child is reaped or handed over.
    handle: linux.fd_t,
    collector: Collector,
    reap_ms: u32,
    /// Null only in fixtures that own a bare child; a bridge always has one.
    admission: ?deadline.Admission,
    /// The one reap phase, fixed by the first wait and never restarted, so
    /// a kill after it times out gets only what is left.
    reaping: ?deadline.Deadline = null,
    stage: Stage = .open,

    pub fn spawn(context: Context, executable: []const u8, reap_ms: u32, admission: deadline.Admission) !Proxy {
        if (builtin.os.tag != .linux) return error.OperationUnsupported;
        try reapable();
        const base = context.source;
        const child = try std.process.spawn(base.io, .{ .argv = &.{ executable, "--internal-host-move" }, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore, .inherit_files = context.authorities, .inherit_dirs = &.{ base.dir, context.target.dir } });
        return own(base.io, child, reap_ms, admission);
    }

    /// Take a child this caller has just spawned and not reaped, before it
    /// has been sent anything. Without a pidfd and a collector the child is
    /// killed and reaped here, and the move is refused.
    pub fn own(io: std.Io, spawned: std.process.Child, reap_ms: u32, admission: ?deadline.Admission) !Proxy {
        if (builtin.os.tag != .linux) return error.OperationUnsupported;
        var child = spawned;
        errdefer discard(io, &child);
        const opened = linux.pidfd_open(child.id orelse return error.ProcessHandleUnavailable, 0);
        if (linux.errno(opened) != .SUCCESS) return error.ProcessHandleUnavailable;
        const handle: linux.fd_t = @intCast(opened);
        errdefer _ = linux.close(handle);
        const collector = try Collector.start(io);
        return .{ .io = io, .child = child, .handle = handle, .collector = collector, .reap_ms = reap_ms, .admission = admission };
    }

    /// The request and COMMIT together fit an empty pipe, so neither write
    /// can wait on a stalled reader.
    pub fn fits(self: *const Proxy) !void {
        if (builtin.os.tag != .linux) return error.OperationUnsupported;
        const size = linux.fcntl(self.child.stdin.?.handle, linux.F.GETPIPE_SZ, 0);
        if (linux.errno(size) != .SUCCESS or size < wire.pipe_bytes) return error.PipeTooSmall;
    }

    /// From here a COMMIT may reach the peer, so the child is never killed.
    pub fn commit(self: *Proxy, allocator: std.mem.Allocator, value: wire.Commit) !void {
        self.stage = .committed;
        try wire.write(allocator, self.io, self.child.stdin.?, value);
        self.shut();
    }

    /// Wait out the reap bound, inside the admission. Null leaves the child
    /// running and unreaped, still this caller's own.
    pub fn reap(self: *Proxy) ?std.process.Child.Term {
        if (builtin.os.tag != .linux) return null;
        if (self.stage == .reaped or self.stage == .abandoned) return null;
        self.shut();
        if (self.child.id == null) {
            self.drop(.abandoned);
            return null;
        }
        const bound = self.reaping orelse if (self.admission) |whole| whole.phase(self.io, self.reap_ms) else deadline.Deadline.after(self.io, self.reap_ms);
        self.reaping = bound;
        bound.ended(self.io, self.handle) catch return null;
        const term = self.child.wait(self.io) catch {
            // wait cleans up id and pipes on failure too. That identity
            // is no longer owned and must never be polled or signalled.
            if (self.child.id == null) self.drop(.abandoned);
            return null;
        };
        self.drop(.reaped);
        return term;
    }

    /// Settle whatever is still owned. Before COMMIT the closed input means
    /// no COMMIT can arrive, so the child never outlives the caller: half
    /// the reap phase to end on its own, then the kill through its pidfd
    /// and the rest of the phase to reap it. After COMMIT it is never
    /// killed: it keeps its inherited gates and leases for as long as its
    /// peer can still rename. It is continued first, so a child that was
    /// only stopped can end inside the bound. Either child still running
    /// then goes to the collector, which reaps it whenever it ends, so
    /// neither outlives this caller as a zombie.
    pub fn close(self: *Proxy) void {
        if (builtin.os.tag != .linux) return;
        if (self.stage == .reaped or self.stage == .abandoned) return;
        self.shut();
        if (self.stage != .open) {
            self.signal(.CONT);
            if (self.reap() != null or self.stage == .abandoned) return;
            return self.abandon();
        }
        if (self.wait(self.reap_ms / 2)) return;
        self.signal(.KILL);
        if (self.wait(self.reap_ms - self.reap_ms / 2)) return;
        self.abandon();
    }

    /// One bounded wait for the child to end, then reap it. False leaves it
    /// owned with the bound only spent, never restarted.
    fn wait(self: *Proxy, ms: u32) bool {
        if (self.child.id == null) {
            self.drop(.abandoned);
            return true;
        }
        const bound = if (self.admission) |whole| whole.phase(self.io, ms) else deadline.Deadline.after(self.io, ms);
        bound.ended(self.io, self.handle) catch return false;
        _ = self.child.wait(self.io) catch {
            // wait cleans up id and pipes on failure too. That identity
            // is no longer owned and must never be polled or signalled.
            if (self.child.id == null) self.drop(.abandoned);
            return false;
        };
        self.drop(.reaped);
        return true;
    }

    fn abandon(self: *Proxy) void {
        if (self.child.stdout) |pipe| pipe.close(self.io);
        self.child.stdout = null;
        self.child.id = null;
        self.collector.adopt(self.handle);
        self.handle = -1;
        self.stage = .abandoned;
    }

    fn signal(self: *const Proxy, sig: linux.SIG) void {
        _ = linux.pidfd_send_signal(self.handle, sig, null, 0);
    }

    fn drop(self: *Proxy, stage: Stage) void {
        _ = linux.close(self.handle);
        self.handle = -1;
        self.collector.release();
        self.stage = stage;
    }

    fn shut(self: *Proxy) void {
        if (self.child.stdin) |pipe| pipe.close(self.io);
        self.child.stdin = null;
    }
};

/// A child the kernel reaps by itself frees its PID while the caller still
/// means it, before its pidfd can be taken. A caller that ignores SIGCHLD,
/// or asks not to wait for children, is refused.
pub fn reapable() !void {
    var old: linux.Sigaction = undefined;
    if (linux.errno(linux.sigaction(.CHLD, null, &old)) != .SUCCESS) return error.Unexpected;
    if (old.handler.handler == linux.SIG.IGN or old.flags & linux.SA.NOCLDWAIT != 0) return error.ChildReapingDisabled;
}

/// Only for a child that was never sent anything.
fn discard(io: std.Io, child: *std.process.Child) void {
    const pid = child.id orelse return;
    _ = linux.kill(pid, .KILL);
    _ = child.wait(io) catch {};
}
