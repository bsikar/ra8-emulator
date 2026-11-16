const builtin = @import("builtin");
const std = @import("std");
const paths = @import("ra8").host.toolchain.paths;

test "a private cache below an unsafe parent cannot be admitted" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const io = std.testing.io;
    try temp.dir.createDir(io, "cache", .fromMode(0o700));
    var buffer: [4096]u8 = undefined;
    const absolute = buffer[0..try temp.dir.realPathFile(io, "cache", &buffer)];
    try temp.dir.setPermissions(io, .fromMode(0o777));
    try std.testing.expectError(error.UnsafeCacheOwnership, paths.cache(io, absolute, false));
    try temp.dir.setPermissions(io, .fromMode(0o1777));
    const cache = try paths.cache(io, absolute, false);
    cache.close(io);
}
