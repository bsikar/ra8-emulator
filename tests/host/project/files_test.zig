const std = @import("std");
const files = @import("ra8").host.project.files;

test "project file reads reject traversal and oversized inputs without changing bytes" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "data", .data = "retained" });
    try std.testing.expectError(error.InvalidPath, files.read(std.testing.allocator, std.testing.io, tmp.dir, "../data", 32));
    try std.testing.expectError(error.ProjectFileLimit, files.read(std.testing.allocator, std.testing.io, tmp.dir, "data", 3));
    const bytes = try files.read(std.testing.allocator, std.testing.io, tmp.dir, "data", 32);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("retained", bytes);
}
