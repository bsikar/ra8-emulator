const std = @import("std");
const digest = @import("ra8").host.toolchain.digest;

test "archive hashing is idempotent and independent of streaming download position" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const file = try temp.dir.createFile(std.testing.io, "archive", .{ .read = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "freshly downloaded archive");
    const expected = digest.bytes("freshly downloaded archive");
    try std.testing.expectEqual(expected, try digest.file(std.testing.io, file, 100));
    try std.testing.expectEqual(expected, try digest.file(std.testing.io, file, 100));
    try std.testing.expectError(error.FileTooLarge, digest.file(std.testing.io, file, 3));
}
