const std = @import("std");
const Fixture = @import("fixture.zig").Fixture;

test "project sources map in both directions and distinguish missing from changed source" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.receipt();
    const elf = try f.project.load(Fixture.receipt_path);
    std.testing.allocator.free(elf);
    var out: [4096]u8 = undefined;
    const host = try f.project.sourcePath("C:/client/project/main.zig", false, &out);
    var mapped: [4096]u8 = undefined;
    try std.testing.expectEqualStrings("C:/client/project/main.zig", try f.project.sourcePath(host, true, &mapped));
    try std.testing.expectError(error.SourceUnavailable, f.project.sourcePath("C:/wrong/project/main.zig", false, &out));
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = "changed" });
    try std.testing.expectError(error.SourceChanged, f.project.sourcePath("C:/client/project/main.zig", false, &out));
    try f.tmp.dir.deleteFile(std.testing.io, "main.zig");
    try std.testing.expectError(error.SourceMissing, f.project.sourcePath("C:/client/project/main.zig", false, &out));
}
