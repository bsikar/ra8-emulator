//! The spawned WSL proxy child: who reaps it, and when it may be signalled.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const wire = @import("wire.zig");
const Deadline = @import("deadline.zig").Deadline;
const Context = @import("context.zig").Context;

pub const Stage = enum { open, committed, reaped, abandoned };

pub const Proxy = struct {
    io: std.Io,
    child: std.process.Child,
    reap_ms: u32,
    stage: Stage = .open,

    pub fn spawn(context: Context, executable: []const u8, reap_ms: u32) !Proxy {
        if (builtin.os.tag != .linux) return error.OperationUnsupported;
        const base = context.source;
        const child = try std.process.spawn(base.io, .{ .argv = &.{ executable, "--internal-host-move" }, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore, .inherit_files = context.authorities, .inherit_dirs = &.{ base.dir, context.target.dir } });
        return .{ .io = base.io, .child = child, .reap_ms = reap_ms };
    }

    /// The request and COMMIT together fit an empty pipe, so neither write
    /// can wait on a stalled reader.
    pub fn fits(self: *const Proxy) !void {
        const size = linux.fcntl(self.child.stdin.?.handle, linux.F.GETPIPE_SZ, 0);
        if (linux.errno(size) != .SUCCESS or size < wire.pipe_bytes) return error.PipeTooSmall;
    }

    /// From here a COMMIT may reach the peer, so the child is never signalled.
    pub fn commit(self: *Proxy, allocator: std.mem.Allocator, value: wire.Commit) !void {
        self.stage = .committed;
        try wire.write(allocator, self.io, self.child.stdin.?, value);
        self.shut();
    }

    /// Wait out the reap bound. Null leaves the child running and unreaped.
    pub fn reap(self: *Proxy) ?std.process.Child.Term {
        if (self.stage == .reaped or self.stage == .abandoned) return null;
        self.shut();
        Deadline.after(self.io, self.reap_ms).exited(self.io, self.child.id.?) catch return null;
        const term = self.child.wait(self.io) catch return null;
        self.stage = .reaped;
        return term;
    }

    /// Settle whatever is still owned. Before COMMIT the closed input means
    /// no COMMIT can arrive, so a child that outlives the reap bound is
    /// killed: it is this caller's own unreaped child. After COMMIT a child
    /// that outlives the bound is left alone with its inherited gates and
    /// leases, which stay held for as long as its peer can still rename.
    pub fn close(self: *Proxy) void {
        if (self.stage == .reaped or self.stage == .abandoned) return;
        const cancelled = self.stage == .open;
        if (self.reap() != null) return;
        if (cancelled) {
            _ = linux.kill(self.child.id.?, .KILL);
            if (self.reap() != null) return;
        }
        if (self.child.stdout) |pipe| pipe.close(self.io);
        self.child.stdout = null;
        self.stage = .abandoned;
    }

    fn shut(self: *Proxy) void {
        if (self.child.stdin) |pipe| pipe.close(self.io);
        self.child.stdin = null;
    }
};
