const std = @import("std");
const builtin = @import("builtin");
const ra8 = @import("ra8");
const Proxy = ra8.host.history.move.proxy.Proxy;
const io = std.testing.io;
const linux = std.os.linux;

fn start(argv: []const []const u8) !Proxy {
    return .{ .io = io, .child = try std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore }), .reap_ms = 300 };
}

fn alive(pid: i32) bool {
    var info: linux.siginfo_t = undefined;
    info.fields.common.first.piduid.pid = 0;
    return linux.errno(linux.waitid(.PID, pid, &info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT, null)) == .SUCCESS and info.fields.common.first.piduid.pid == 0;
}

test "a child that ends with its input is reaped inside the bound unsignalled" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var child = try start(&.{"/bin/cat"});
    try child.fits();
    try std.testing.expect(child.reap().?.success());
    child.close();
    try std.testing.expectEqual(ra8.host.history.move.proxy.Stage.reaped, child.stage);
}

test "before COMMIT a child that outlives the bound is killed and reaped" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var child = try start(&.{ "/bin/sleep", "600" });
    const begun = std.Io.Timestamp.now(io, .awake);
    child.close();
    try std.testing.expectEqual(ra8.host.history.move.proxy.Stage.reaped, child.stage);
    try std.testing.expect(begun.untilNow(io, .awake).toMilliseconds() < 3000);
}

test "after COMMIT a child that outlives the bound is left running and unsignalled" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var child = try start(&.{ "/bin/sleep", "600" });
    const pid = child.child.id.?;
    const nonce: ra8.host.history.name.Id = @splat('c');
    try child.commit(std.testing.allocator, .{ .nonce = nonce, .commit = true });
    const begun = std.Io.Timestamp.now(io, .awake);
    try std.testing.expectEqual(@as(?std.process.Child.Term, null), child.reap());
    child.close();
    try std.testing.expect(begun.untilNow(io, .awake).toMilliseconds() < 3000);
    try std.testing.expectEqual(ra8.host.history.move.proxy.Stage.abandoned, child.stage);
    try std.testing.expect(alive(pid));
    // The fixture is this test's own unreaped child.
    _ = linux.kill(pid, .KILL);
    var status: i32 = 0;
    _ = linux.wait4(pid, &status, 0, null);
}

fn failedWait(userdata: ?*anyopaque, child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
    // Exercise the real wait cleanup, then inject its documented error.
    _ = try io.vtable.childWait(userdata, child);
    return error.Canceled;
}

test "failed wait drops child ownership before close or another reap" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var child = try start(&.{"/bin/true"});
    defer child.close();
    var vtable = io.vtable.*;
    vtable.childWait = failedWait;
    child.io.vtable = &vtable;
    try std.testing.expectEqual(@as(?std.process.Child.Term, null), child.reap());
    try std.testing.expectEqual(@as(?std.process.Child.Id, null), child.child.id);
    child.close();
    try std.testing.expectEqual(ra8.host.history.move.proxy.Stage.abandoned, child.stage);
    try std.testing.expectEqual(@as(?std.process.Child.Term, null), child.reap());
    try std.testing.expect(child.child.stdin == null and child.child.stdout == null);
}

test "insufficient request pipe capacity is rejected before use" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var child = try start(&.{"/bin/cat"});
    defer child.close();
    const size = linux.fcntl(child.child.stdin.?.handle, linux.F.SETPIPE_SZ, 4096);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(size));
    try std.testing.expectError(error.PipeTooSmall, child.fits());
    try std.testing.expectEqual(ra8.host.history.move.proxy.Stage.open, child.stage);
}
