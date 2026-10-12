//! The portable anonymous pipe delivers bytes and reports writer closure.
const std = @import("std");
const ra8 = @import("ra8");

test "a pipe pair starts idle, delivers bytes and ends when its writer closes" {
    const ends = try ra8.host.pipe_pair.create(.{ .nonblocking = true });
    defer ra8.host.read.close(ends[0]);
    var writer_open = true;
    defer if (writer_open) ra8.host.read.close(ends[1]);
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), ra8.host.read.read(ends[0], &bytes));
    const writer: std.Io.File = .{ .handle = ends[1], .flags = .{ .nonblocking = false } };
    try writer.writeStreamingAll(std.testing.io, "pipe");
    try std.testing.expectEqual(@as(?usize, 4), ra8.host.read.read(ends[0], &bytes));
    try std.testing.expectEqualStrings("pipe", bytes[0..4]);
    ra8.host.read.close(ends[1]);
    writer_open = false;
    try std.testing.expectEqual(@as(?usize, 0), ra8.host.read.read(ends[0], &bytes));
}
