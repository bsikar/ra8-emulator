const std = @import("std");
const path = @import("ra8").host.workspace.path;

test "workspace paths normalize native separators and refuse escapes and aliases" {
    var buffer: [path.capacity]u8 = undefined;
    try std.testing.expectEqualStrings("src/main.zig", try path.normalize("./src\\main.zig", &buffer));
    try std.testing.expectEqualStrings("", try path.normalize(".", &buffer));
    for ([_][]const u8{ "../outside", "src/../../outside", "/etc/passwd", "\\\\host\\share", "C:main.zig", "C:/main.zig", "file:stream", "a\x00b", "name.", "name " }) |name| {
        try std.testing.expectError(error.InvalidPath, path.normalize(name, &buffer));
    }
    var small: [2]u8 = undefined;
    try std.testing.expectError(error.NameTooLong, path.normalize("src", &small));
}
