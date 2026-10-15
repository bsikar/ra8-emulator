const std = @import("std");
const builtin = @import("builtin");
const ra8 = @import("ra8");
const wire = ra8.host.history.move.wire;
const Deadline = ra8.host.history.move.deadline.Deadline;
const Admission = ra8.host.history.move.deadline.Admission;
const io = std.testing.io;
const linux = std.os.linux;

fn pipe() ![2]std.Io.File {
    const ends = try ra8.host.pipe_pair.create(.{});
    return .{ .{ .handle = ends[0], .flags = .{ .nonblocking = false } }, .{ .handle = ends[1], .flags = .{ .nonblocking = false } } };
}

fn commit(nonce: ra8.host.history.name.Id) wire.Commit {
    return .{ .version = wire.version, .nonce = nonce, .operation = @splat('e'), .proof = .{ .anchor = wire.digest("a"), .note = wire.digest("n") }, .commit = true };
}

test "a passed bound has no time left and a fresh one rounds up" {
    try std.testing.expectEqual(@as(?i32, null), (Deadline{ .end = std.Io.Timestamp.now(io, .awake) }).left(io));
    const left = Deadline.after(io, 1000).left(io).?;
    try std.testing.expect(left > 0 and left <= 1000);
}

test "a silent or half-written frame ends at the bound with its writer still open" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    for ([_][]const u8{ "", &.{ 9, 0 }, &.{ 9, 0, 0, 0, '{' } }) |sent| {
        const ends = try pipe();
        defer ends[0].close(io);
        defer ends[1].close(io);
        if (sent.len != 0) try ends[1].writeStreamingAll(io, sent);
        const start = std.Io.Timestamp.now(io, .awake);
        try std.testing.expectError(error.DeadlineExceeded, wire.read(wire.Commit, std.testing.allocator, io, ends[0], .after(io, 150)));
        const ms = start.untilNow(io, .awake).toMilliseconds();
        try std.testing.expect(ms >= 150 and ms < 2000);
    }
}

test "a bounded read still reports a closed writer and a whole frame at once" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const closed = try pipe();
    defer closed[0].close(io);
    closed[1].close(io);
    try std.testing.expectError(error.EndOfStream, wire.read(wire.Commit, std.testing.allocator, io, closed[0], .after(io, 5000)));
    const ends = try pipe();
    defer ends[0].close(io);
    defer ends[1].close(io);
    try wire.write(std.testing.allocator, io, ends[1], commit(@splat('b')));
    const parsed = try wire.read(wire.Commit, std.testing.allocator, io, ends[0], .after(io, 5000));
    defer parsed.deinit();
    try std.testing.expect(parsed.value.commit and parsed.value.version == wire.version);
}

test "a phase never ends after its admission and a later phase does not reset it" {
    const admission: Admission = .begin(io, 200);
    const long = admission.phase(io, 60_000);
    try std.testing.expect(long.left(io).? <= 200);
    const short = admission.phase(io, 50);
    try std.testing.expect(short.left(io).? <= 50);
    try std.testing.expect(admission.open(io));
    std.Io.sleep(io, .fromMilliseconds(250), .awake) catch {};
    try std.testing.expect(!admission.open(io));
    // A phase begun after the admission ended has no time at all.
    try std.testing.expectEqual(@as(?i32, null), admission.phase(io, 10_000).left(io));
    try std.testing.expectEqual(@as(?i32, null), long.left(io));
}

test "an exhausted admission bounds a read that its own phase would still allow" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const ends = try pipe();
    defer ends[0].close(io);
    defer ends[1].close(io);
    const admission: Admission = .begin(io, 100);
    const start = std.Io.Timestamp.now(io, .awake);
    try std.testing.expectError(error.DeadlineExceeded, wire.read(wire.Commit, std.testing.allocator, io, ends[0], admission.phase(io, 10_000)));
    const ms = start.untilNow(io, .awake).toMilliseconds();
    try std.testing.expect(ms >= 100 and ms < 2000);
}

test "the earlier of two bounds wins either way round" {
    const near = Deadline.after(io, 100);
    const far = Deadline.after(io, 10_000);
    try std.testing.expect(near.min(far).left(io).? <= 100);
    try std.testing.expect(far.min(near).left(io).? <= 100);
}

test "a retained handle reports its own child's exit and times out while it runs" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var child = try std.process.spawn(io, .{ .argv = &.{"/bin/cat"}, .stdin = .pipe, .stdout = .ignore, .stderr = .ignore });
    const opened = linux.pidfd_open(child.id.?, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(opened));
    const handle: linux.fd_t = @intCast(opened);
    defer _ = linux.close(handle);
    try std.testing.expectError(error.DeadlineExceeded, Deadline.after(io, 100).ended(io, handle));
    child.stdin.?.close(io);
    child.stdin = null;
    try Deadline.after(io, 5000).ended(io, handle);
    try std.testing.expect((try child.wait(io)).success());
}
