const std = @import("std");
const builtin = @import("builtin");
const Collector = @import("ra8").host.history.move.collector.Collector;
const io = std.testing.io;
const linux = std.os.linux;

fn handle(child: std.process.Child) !linux.fd_t {
    const opened = linux.pidfd_open(child.id.?, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(opened));
    return @intCast(opened);
}

fn collected(pid: i32) bool {
    var info: linux.siginfo_t = undefined;
    for (0..300) |_| {
        if (linux.errno(linux.waitid(.PID, pid, &info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT, null)) == .CHILD) return true;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    return false;
}

test "a released collector ends without touching the caller's child" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var child = try std.process.spawn(io, .{ .argv = &.{"/bin/true"}, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    const collector = try Collector.start(io);
    collector.release();
    std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
    // Still the caller's to reap: the collector never waited on it.
    try std.testing.expect((try child.wait(io)).success());
}

test "an adopted child is continued while stopped and reaped once it ends" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const child = try std.process.spawn(io, .{ .argv = &.{ "/bin/sleep", "0.2" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    const pid = child.id.?;
    // The fixture is this test's own unreaped child.
    _ = linux.kill(pid, .STOP);
    const collector = try Collector.start(io);
    collector.adopt(try handle(child));
    try std.testing.expect(collected(pid));
}
