const std = @import("std");
const line = @import("ra8").session.dwarf.line;
const paths = line.path;

test "compilation directories qualify source queries without matching another same-named file" {
    const file: line.File = .{ .compilation_directory = "C:\\Project With Spaces", .name = "machine.zig" };
    try std.testing.expect(paths.named(file, "C:/Project With Spaces/machine.zig"));
    try std.testing.expect(paths.named(file, "c:\\project with spaces\\MACHINE.ZIG"));
    try std.testing.expect(paths.named(file, "machine.zig"));
    try std.testing.expect(!paths.named(file, "C:/Other Project/machine.zig"));
    try std.testing.expect(!paths.named(file, "D:/Project With Spaces/machine.zig"));
    try std.testing.expect(!paths.named(.{ .name = "machine.zig" }, "C:/Project With Spaces/machine.zig"));
    try std.testing.expect(!paths.named(.{ .compilation_directory = "/project" }, "/project"));
}

test "source composition respects absolute names and directories and normalizes relative directory components" {
    const relative: line.File = .{ .compilation_directory = "/build/project", .directory = "src/../include/.", .name = "main.c" };
    try std.testing.expect(paths.named(relative, "/build/project/include/main.c"));
    try std.testing.expect(!paths.named(relative, "/build/project/src/main.c"));
    try std.testing.expect(paths.named(.{ .compilation_directory = "/wrong", .directory = "/actual/src", .name = "main.c" }, "/actual/src/main.c"));
    try std.testing.expect(paths.named(.{ .compilation_directory = "/wrong", .directory = "/also-wrong", .name = "/actual/main.c" }, "/actual/main.c"));
    try std.testing.expect(!paths.named(.{ .compilation_directory = "/Actual", .name = "Main.c" }, "/actual/Main.c"));
    try std.testing.expect(paths.named(.{ .compilation_directory = "//server/share/project", .name = "main.c" }, "\\\\server\\share\\project\\main.c"));
    try std.testing.expect(!paths.named(.{ .compilation_directory = "//server/share/project", .name = "main.c" }, "//server/other/project/main.c"));
    try std.testing.expect(!paths.named(.{ .compilation_directory = "C:", .name = "main.c" }, "C:/main.c"));
    try std.testing.expect(!paths.named(.{ .compilation_directory = "C:/project", .directory = "D:src", .name = "main.c" }, "D:/src/main.c"));
}

test "source display includes CU directory once and leaves missing filenames unknown" {
    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try paths.write(&out, .{ .compilation_directory = "/project/", .directory = "src", .name = "main.c" });
    try std.testing.expectEqualStrings("/project/src/main.c", out.buffered());
    out = .fixed(&buffer);
    try paths.write(&out, .{ .compilation_directory = "/project" });
    try std.testing.expectEqualStrings("", out.buffered());
    out = .fixed(&buffer);
    try paths.write(&out, .{ .compilation_directory = "C:", .name = "main.c" });
    try std.testing.expectEqualStrings("C:main.c", out.buffered());
}

test "rooted source readers retain raw paths while DAP can request compilation-qualified paths" {
    const source = @import("ra8").session.source;
    const file: line.File = .{ .compilation_directory = "/compiler/project", .name = "main.c" };
    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try source.path(&out, file);
    try std.testing.expectEqualStrings("main.c", out.buffered());
    out = .fixed(&buffer);
    try source.qualifiedPath(&out, file);
    try std.testing.expectEqualStrings("/compiler/project/main.c", out.buffered());
}
