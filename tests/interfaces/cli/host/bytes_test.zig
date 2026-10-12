//! Covers src/interfaces/cli/host/bytes.zig: a host handle as a model's
//! byte source, read without waiting.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const host_bytes = cli_app.cli.host.bytes;

test "a host pipe read through its byte source" {
    const ends = try ra8.host.pipe_pair.create(.{ .nonblocking = true });
    defer ra8.host.read.close(ends[0]);
    const source = host_bytes.of(ends[0]);
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), source.read(&bytes));
    const end: std.Io.File = .{ .handle = ends[1], .flags = .{ .nonblocking = false } };
    try end.writeStreamingAll(std.testing.io, "ok");
    try std.testing.expectEqual(@as(?usize, 2), source.read(&bytes));
    try std.testing.expectEqualStrings("ok", bytes[0..2]);
    ra8.host.read.close(ends[1]);
    try std.testing.expectEqual(@as(?usize, 0), source.read(&bytes));
}

test "a missing touch file is refused at open" {
    try std.testing.expectError(error.FileNotFound, host_bytes.open(std.testing.io, "--touch @", "/nonexistent/ra8-touch"));
}
