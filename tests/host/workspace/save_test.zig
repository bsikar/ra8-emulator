const std = @import("std");
const workspace = @import("ra8").host.workspace;
const io = std.testing.io;

test "workspace saves create exclusively and reject stale versions without losing bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var files: workspace.Workspace = .{ .dir = tmp.dir, .io = io };
    const original = try files.write("main.zig", "original", .{});
    try std.testing.expectError(error.Conflict, files.write("main.zig", "clobber", .{}));
    const saved = try files.write("main.zig", "edited", original);
    try std.testing.expect(!original.same(saved));
    try std.testing.expectError(error.Conflict, files.write("main.zig", "stale", original));
    var bytes: [32]u8 = undefined;
    try std.testing.expectEqualStrings("edited", (try files.read("main.zig", 0, &bytes)).bytes);
    try std.testing.expectError(error.NotFile, files.write("", "bad", .{}));
}
