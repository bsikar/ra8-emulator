const std = @import("std");
const cli = @import("cli_app").serve.main;

test "backend builds require an explicit absolute compiler and workspace" {
    const compiler = if (@import("builtin").os.tag == .windows) "C:/tools/zig.exe" else "/tools/zig";
    try std.testing.expect(cli.parse(&.{ "ra8", "serve", "--build-zig", compiler, "--stdio", "fw.elf" }) == null);
    try std.testing.expect(cli.parse(&.{ "ra8", "serve", "--workspace", ".", "--build-zig", "zig", "--stdio", "fw.elf" }) == null);
    const enabled = cli.parse(&.{ "ra8", "serve", "--build-zig", compiler, "--workspace", ".", "--stdio", "fw.elf" }).?;
    try std.testing.expectEqualStrings(compiler, enabled.build_zig.?);
    if (@import("builtin").os.tag == .windows) {
        try std.testing.expect(cli.parse(&.{ "ra8", "serve", "--workspace", ".", "--build-zig", "\\tools\\zig.exe", "--stdio", "fw.elf" }) == null);
    }
}

test "serve workspace access requires one explicit nonempty root" {
    const plain = cli.parse(&.{ "ra8", "serve", "--stdio", "firmware.elf" }).?;
    try std.testing.expectEqual(@as(?[]const u8, null), plain.workspace);
    const enabled = cli.parse(&.{ "ra8", "serve", "--workspace", "project with spaces", "--stdio", "firmware.elf" }).?;
    try std.testing.expectEqualStrings("project with spaces", enabled.workspace.?);
    try std.testing.expectEqualStrings("firmware.elf", enabled.elf);
    try std.testing.expect(cli.parse(&.{ "ra8", "serve", "--workspace", "", "--stdio", "fw.elf" }) == null);
    try std.testing.expect(cli.parse(&.{ "ra8", "serve", "--workspace", "one", "--workspace", "two", "--stdio", "fw.elf" }) == null);
    try std.testing.expect(cli.parse(&.{ "ra8", "serve", "--workspace" }) == null);
}
