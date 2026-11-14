//! A build process tree, owned and polled by exactly one worker.
const std = @import("std");
const builtin = @import("builtin");
const windows = @import("../win32.zig");
pub const supported = builtin.os.tag == .windows or builtin.os.tag == .linux or builtin.os.tag == .macos;
const on_windows = builtin.os.tag == .windows;
const darwin = struct {
    // Darwin sys/wait.h: P_PID, WEXITED and WNOWAIT. Zig's std.c does not
    // expose waitid or these constants on macOS yet. No status is reaped here.
    extern "c" fn waitid(c_uint, c_uint, *std.c.siginfo_t, c_int) c_int;
    extern "c" fn proc_listpids(u32, u32, *anyopaque, c_int) c_int;
    const pid = 1;
    const exited = 0x04;
    const nowait = 0x20;

    fn onlyRoot(group: std.posix.pid_t) !bool {
        var ids: [1024]std.posix.pid_t = undefined;
        // PROC_PGRP_ONLY returns bytes; a full buffer cannot establish completeness.
        const size = proc_listpids(2, @intCast(group), &ids, @sizeOf(@TypeOf(ids)));
        if (size <= 0 or size >= @sizeOf(@TypeOf(ids)) or @mod(size, @sizeOf(std.posix.pid_t)) != 0) return error.ProcessGroupInspectionFailed;
        for (ids[0..@intCast(@divExact(size, @sizeOf(std.posix.pid_t)))]) |id| if (id != group) return false;
        return true;
    }
};

pub const Process = struct {
    child: std.process.Child,
    io: std.Io,
    job: ?windows.HANDLE = null,
    lost: bool = false,
    tree_stopped: bool = false,

    pub fn spawn(io: std.Io, argv: []const []const u8, cwd: std.Io.Dir) !Process {
        if (!supported) return error.UnsupportedPlatform;
        const job: ?windows.HANDLE = if (on_windows) try makeJob() else null;
        errdefer if (on_windows) if (job) |handle| std.os.windows.CloseHandle(handle);
        var child = try std.process.spawn(io, .{ .argv = argv, .cwd = if (builtin.os.tag == .macos and cwd.handle == std.Io.Dir.cwd().handle) .inherit else .{ .dir = cwd }, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe, .pgid = if (on_windows) null else 0, .start_suspended = on_windows, .create_no_window = true });
        errdefer child.kill(io);
        if (on_windows) {
            if (!windows.AssignProcessToJobObject(job.?, child.id.?).toBool()) return error.JobAssignmentFailed;
            if (std.os.windows.ntdll.NtResumeThread(child.thread_handle, null) != .SUCCESS) return error.ResumeFailed;
        }
        return .{ .child = child, .io = io, .job = job };
    }

    /// Observes exit without reaping: the child's identity remains pinned for tree cleanup.
    pub fn exited(self: *Process) !bool {
        const id = self.child.id orelse return true;
        if (on_windows) {
            var timeout: i64 = 0;
            return switch (std.os.windows.ntdll.NtWaitForSingleObject(id, .FALSE, &timeout)) {
                .SUCCESS => true,
                .TIMEOUT => false,
                else => error.ProcessWaitFailed,
            };
        } else if (builtin.os.tag == .linux) {
            var info = std.mem.zeroes(std.os.linux.siginfo_t);
            const rc = std.os.linux.waitid(.PID, id, &info, std.os.linux.W.EXITED | std.os.linux.W.NOHANG | std.os.linux.W.NOWAIT, null);
            return switch (std.os.linux.errno(rc)) {
                .SUCCESS => info.code != 0,
                .INTR => false,
                .CHILD => blk: {
                    self.lost = true;
                    break :blk error.ChildOwnershipLost;
                },
                else => error.ProcessWaitFailed,
            };
        } else if (builtin.os.tag == .macos) {
            var info = std.mem.zeroes(std.c.siginfo_t);
            const rc = darwin.waitid(darwin.pid, @intCast(id), &info, darwin.exited | std.c.W.NOHANG | darwin.nowait);
            return switch (std.c.errno(rc)) {
                .SUCCESS => info.pid != 0,
                .INTR => false,
                .CHILD => blk: {
                    self.lost = true;
                    break :blk error.ChildOwnershipLost;
                },
                else => error.ProcessWaitFailed,
            };
        } else return error.UnsupportedPlatform;
    }

    pub fn stopTree(self: *Process) !void {
        if (self.tree_stopped or self.child.id == null) return;
        if (self.lost) return error.ChildOwnershipLost;
        if (on_windows) {
            if (!windows.TerminateJobObject(self.job.?, 1).toBool()) return error.TreeStopFailed;
        } else std.posix.kill(-self.child.id.?, .KILL) catch |err| switch (err) {
            error.ProcessNotFound => {},
            // Darwin filters zombies from group signalling and reports EPERM
            // for an otherwise empty group. Do not hide a live-member denial.
            error.PermissionDenied => if (builtin.os.tag != .macos or !try self.exited() or !try darwin.onlyRoot(self.child.id.?)) return err,
            else => return err,
        };
        self.tree_stopped = true;
    }

    pub fn finish(self: *Process) !std.process.Child.Term {
        try self.stopTree();
        return self.child.wait(self.io);
    }

    pub fn close(self: *Process) !void {
        var failure: ?anyerror = null;
        if (self.child.id != null) {
            if (!self.lost) {
                self.stopTree() catch |err| {
                    failure = err;
                };
                self.child.kill(self.io);
            } else {
                if (self.child.stdout) |file| file.close(self.io);
                if (self.child.stderr) |file| file.close(self.io);
                self.child.id = null;
                failure = error.ChildOwnershipLost;
            }
        }
        if (on_windows) if (self.job) |job| {
            std.os.windows.CloseHandle(job);
            self.job = null;
        };
        if (failure) |err| return err;
    }
};

fn makeJob() !windows.HANDLE {
    const job = windows.CreateJobObjectW(null, null) orelse return error.JobCreationFailed;
    errdefer std.os.windows.CloseHandle(job);
    var limits: windows.JobLimits = .{};
    limits.basic.flags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE.
    if (!windows.SetInformationJobObject(job, 9, &limits, @sizeOf(windows.JobLimits)).toBool()) return error.JobLimitsFailed;
    return job;
}
