const std = @import("std");
const map = @import("ra8").host.project.map;

test "source mapping uses lexical component boundaries across client and server platforms" {
    var buffer: [4096]u8 = undefined;
    try std.testing.expectEqualStrings("C:/client/project/main.zig", try map.normalize("C:\\client\\project\\src\\..\\main.zig", &buffer));
    try std.testing.expect(map.prefix("c:/CLIENT/project/main.zig", "C:/client/project"));
    try std.testing.expect(!map.prefix("/server/project-two/main.zig", "/server/project"));
    try std.testing.expect(!map.prefix("/SERVER/project/main.zig", "/server/project"));
    try std.testing.expectEqualStrings("/server/project/main.zig", try map.replace("C:/client/project/main.zig", "C:/client/project", "/server/project", &buffer));
    try std.testing.expectEqualStrings("C:/client/project/main.zig", try map.replace("/server/project/main.zig", "/server/project", "C:/client/project", &buffer));
    try std.testing.expectError(error.SourceUnavailable, map.normalize("/../../escape.zig", &buffer));
    try std.testing.expectError(error.SourceUnavailable, map.normalize("relative/main.zig", &buffer));
}
