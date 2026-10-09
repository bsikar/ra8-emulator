//! A host disk image read whole, and capped.
const std = @import("std");
const io = std.testing.io;
const disk_file = @import("ra8").host.disk_file;

test "a file is read whole up to the cap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "d.img", .data = &(@as([512]u8, @splat(0x55))) });
    const path = try tmp.dir.realPathFileAlloc(io, "d.img", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const bytes = try disk_file.read(std.testing.allocator, io, path, 4096);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 512), bytes.len);
    try std.testing.expectError(error.StreamTooLong, disk_file.read(std.testing.allocator, io, path, 100));
}
