//! A host folder as the SD card builder sees it.
const std = @import("std");
const io = std.testing.io;
const Folder = @import("ra8").host.folder.Folder;

test "a folder lists files and subfolders, sizes and reads them" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello" });
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/b.txt", .data = "xy" });
    const folder = Folder.of(io, tmp.dir);
    const entries = try folder.list(std.testing.allocator);
    defer Folder.free(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    var files: usize = 0;
    var dirs: usize = 0;
    for (entries) |entry| switch (entry.kind) {
        .file => files += 1,
        .directory => dirs += 1,
        .other => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), files);
    try std.testing.expectEqual(@as(usize, 1), dirs);
    try std.testing.expectEqual(@as(u64, 5), try folder.size("a.txt"));
    var sub = try folder.sub("sub");
    defer sub.close();
    const bytes = try sub.read(std.testing.allocator, "b.txt");
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("xy", bytes);
}
