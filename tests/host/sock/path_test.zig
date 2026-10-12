const std = @import("std");
const builtin = @import("builtin");
const socket_path = @import("ra8").host.sock.path;

test "Unix normalization resolves the parent without requiring a socket file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, ".zig-cache/tmp/{s}/absent.sock", .{tmp.sub_path});
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try socket_path.unix(std.testing.io, name, &buffer);
    if (builtin.os.tag == .windows) {
        try std.testing.expect(std.fs.path.isAbsolute(path));
        try std.testing.expectEqualStrings("absent.sock", std.fs.path.basename(path));
    } else try std.testing.expectEqualStrings(name, path);
}
