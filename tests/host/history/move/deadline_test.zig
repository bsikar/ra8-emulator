const std = @import("std");
const builtin = @import("builtin");
const ra8 = @import("ra8");
const wire = ra8.host.history.move.wire;
const Deadline = ra8.host.history.move.deadline.Deadline;
const io = std.testing.io;

fn pipe() ![2]std.Io.File {
    const ends = try ra8.host.pipe_pair.create(.{});
    return .{ .{ .handle = ends[0], .flags = .{ .nonblocking = false } }, .{ .handle = ends[1], .flags = .{ .nonblocking = false } } };
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
    const nonce: ra8.host.history.name.Id = @splat('b');
    try wire.write(std.testing.allocator, io, ends[1], wire.Commit{ .nonce = nonce, .commit = true });
    const parsed = try wire.read(wire.Commit, std.testing.allocator, io, ends[0], .after(io, 5000));
    defer parsed.deinit();
    try std.testing.expect(parsed.value.commit and parsed.value.version == 2);
}
