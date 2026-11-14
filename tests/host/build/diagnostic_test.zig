const std = @import("std");
const diagnostic = @import("ra8").host.build.diagnostic;

test "build diagnostics preserve native drive paths and message colons" {
    const linux = diagnostic.parse("src/main.zig:12:3: error: expected expression\n").?;
    try std.testing.expectEqualStrings("src/main.zig", linux.path);
    try std.testing.expectEqual(@as(u32, 12), linux.line);
    try std.testing.expectEqual(@as(u32, 3), linux.column);
    try std.testing.expectEqualStrings("error: expected expression", linux.message);
    const windows = diagnostic.parse("C:\\project space\\main.zig:42:9: error: invalid type: u8\r\n").?;
    try std.testing.expectEqualStrings("C:\\project space\\main.zig", windows.path);
    try std.testing.expectEqual(@as(u32, 42), windows.line);
    try std.testing.expect(diagnostic.parse("error: the compiler could not run") == null);
    try std.testing.expect(diagnostic.parse("file.zig:0:1: error: bad") == null);
}
