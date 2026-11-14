const std = @import("std");
const host = @import("ra8").host;
const io = std.testing.io;

test "build output polling distinguishes empty pipes from EOF and preserves bytes" {
    const ends = try host.pipe_pair.create(.{});
    const input: std.Io.File = .{ .handle = ends[0], .flags = .{ .nonblocking = false } };
    defer input.close(io);
    const output: std.Io.File = .{ .handle = ends[1], .flags = .{ .nonblocking = false } };
    var output_open = true;
    defer if (output_open) output.close(io);
    var bytes: [32]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), try host.build.pipe.read(io, input, &bytes));
    try output.writeStreamingAll(io, "output");
    const got = (try host.build.pipe.read(io, input, &bytes)).?;
    try std.testing.expectEqualStrings("output", bytes[0..got]);
    output.close(io);
    output_open = false;
    try std.testing.expectEqual(@as(?usize, 0), try host.build.pipe.read(io, input, &bytes));
}
