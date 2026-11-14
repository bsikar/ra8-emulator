const std = @import("std");
const Runner = @import("ra8").host.build.Runner;

test "explicit build compiler paths cannot depend on PATH or the current Windows drive" {
    try std.testing.expectError(error.InvalidCompiler, Runner.validateCompiler("zig"));
    try std.testing.expectError(error.InvalidCompiler, Runner.validateCompiler(""));
    try std.testing.expectError(error.InvalidCompiler, Runner.validateCompiler("tools/zig"));
    if (@import("builtin").os.tag == .windows) {
        try Runner.validateCompiler("C:/tools with spaces/zig.exe");
        try Runner.validateCompiler("\\\\server\\share\\zig.exe");
        for ([_][]const u8{ "C:zig.exe", "/tools/zig.exe", "\\tools\\zig.exe" }) |path| {
            try std.testing.expectError(error.InvalidCompiler, Runner.validateCompiler(path));
        }
    } else try Runner.validateCompiler("/tools with spaces/zig");
}
